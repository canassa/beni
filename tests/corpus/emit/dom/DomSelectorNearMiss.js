import { deep as _derived$deep } from "./_core/_derived.mjs";
import { Rt$template, Rt$empty, Rt$forKeyed, Rt$rowsHead, Rt$rowsTail, Rt$rowsRestate, Rt$rowsDispose, Rt$positionHead, Rt$positionTail, Rt$positionRestate, Rt$positionDispose, Rt$forPosition, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { Maybe$withDefault, Maybe$Maybe$$eq } from "./_core/Maybe.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomSelectorNearMiss$t68 = Rt$template("<p> ");
const DomSelectorNearMiss$domNoRestate = ($value$31) => {
};
const DomSelectorNearMiss$domRowView = ($value$32) => $value$32;
const DomSelectorNearMiss$domRowItem = ($value$33) => $value$33.x;
const DomSelectorNearMiss$domRowSameItem = ($value$34, $value$35) => $value$34.x === $value$35;
const DomSelectorNearMiss$domRowSetItem = ($value$36, $value$37) => {
  $value$36.x = $value$37;
};
const DomSelectorNearMiss$domSame12 = ($was$38, $now$39) => $was$38 !== Rt$empty && $was$38[0] === $now$39[0];
const DomSelectorNearMiss$domRememberAll = ($value$40) => $value$40;
const DomSelectorNearMiss$domNoProbe = ($value$41) => Rt$empty;
const DomSelectorNearMiss$domSite12 = { head: ($scope$42, $data$43, $slot$44) => Rt$rowsHead("core:Basics.Int", $scope$42, $data$43, $slot$44), tail: ($scope$46, $data$47, $slot$48) => Rt$rowsTail("core:Basics.Int", $scope$46, $data$47, $slot$48), restate: ($scope$50, $data$51, $slot$52, $stamp$53) => Rt$rowsRestate("core:Basics.Int", $scope$50, $data$51, $slot$52, $stamp$53), dispose: ($scope$54, $data$55, $slot$56) => Rt$rowsDispose("core:Basics.Int", $scope$54, $data$55, $slot$56) };
const DomSelectorNearMiss$t98 = Rt$template("<p> ");
const DomSelectorNearMiss$domSame13 = ($was$72, $now$73) => $was$72 !== Rt$empty && $was$72[0] === $now$73[0];
const DomSelectorNearMiss$domSite13 = { head: ($scope$74, $data$75, $slot$76) => Rt$rowsHead("core:Basics.Int", $scope$74, $data$75, $slot$76), tail: ($scope$78, $data$79, $slot$80) => Rt$rowsTail("core:Basics.Int", $scope$78, $data$79, $slot$80), restate: ($scope$82, $data$83, $slot$84, $stamp$85) => Rt$rowsRestate("core:Basics.Int", $scope$82, $data$83, $slot$84, $stamp$85), dispose: ($scope$86, $data$87, $slot$88) => Rt$rowsDispose("core:Basics.Int", $scope$86, $data$87, $slot$88) };
const DomSelectorNearMiss$t127 = Rt$template("<p> ");
const DomSelectorNearMiss$domSame14 = ($was$104, $now$105) => $was$104 !== Rt$empty && $was$104[0] === $now$105[0];
const DomSelectorNearMiss$domSite14 = { head: ($scope$106, $data$107, $slot$108) => Rt$rowsHead("core:Basics.Int", $scope$106, $data$107, $slot$108), tail: ($scope$110, $data$111, $slot$112) => Rt$rowsTail("core:Basics.Int", $scope$110, $data$111, $slot$112), restate: ($scope$114, $data$115, $slot$116, $stamp$117) => Rt$rowsRestate("core:Basics.Int", $scope$114, $data$115, $slot$116, $stamp$117), dispose: ($scope$118, $data$119, $slot$120) => Rt$rowsDispose("core:Basics.Int", $scope$118, $data$119, $slot$120) };
const DomSelectorNearMiss$t152 = Rt$template("<p> ");
const DomSelectorNearMiss$domSame15 = ($was$136, $now$137) => $was$136 !== Rt$empty && $was$136[0] === $now$137[0];
const DomSelectorNearMiss$domPositionSite = { head: ($scope$138, $data$139, $slot$140) => Rt$positionHead($scope$138, $data$139, $slot$140), tail: ($scope$142, $data$143, $slot$144) => Rt$positionTail($scope$142, $data$143, $slot$144), restate: ($scope$146, $data$147, $slot$148, $stamp$149) => Rt$positionRestate($scope$146, $data$147, $slot$148, $stamp$149), dispose: ($scope$150, $data$151, $slot$152) => Rt$positionDispose($scope$150, $data$151, $slot$152) };
const DomSelectorNearMiss$t200 = Rt$template("<p> ");
const DomSelectorNearMiss$domSame17 = ($was$168, $now$169) => $was$168 !== Rt$empty && $was$168[0] === $now$169[0];
const DomSelectorNearMiss$domSite17 = { head: ($scope$170, $data$171, $slot$172) => Rt$rowsHead("core:Basics.Int", $scope$170, $data$171, $slot$172), tail: ($scope$174, $data$175, $slot$176) => Rt$rowsTail("core:Basics.Int", $scope$174, $data$175, $slot$176), restate: ($scope$178, $data$179, $slot$180, $stamp$181) => Rt$rowsRestate("core:Basics.Int", $scope$178, $data$179, $slot$180, $stamp$181), dispose: ($scope$182, $data$183, $slot$184) => Rt$rowsDispose("core:Basics.Int", $scope$182, $data$183, $slot$184) };
const DomSelectorNearMiss$t180 = Rt$template("<p> ");
const DomSelectorNearMiss$domSameNever = ($value$206, $value$207) => false;
const DomSelectorNearMiss$domRemember16 = ($inputs$208) => [undefined];
const DomSelectorNearMiss$domSite16 = { head: ($scope$209, $data$210, $slot$211) => Rt$rowsHead("core:Basics.Int", $scope$209, $data$210, $slot$211), tail: ($scope$213, $data$214, $slot$215) => Rt$rowsTail("core:Basics.Int", $scope$213, $data$214, $slot$215), restate: ($scope$217, $data$218, $slot$219, $stamp$220) => Rt$rowsRestate("core:Basics.Int", $scope$217, $data$218, $slot$219, $stamp$220), dispose: ($scope$221, $data$222, $slot$223) => Rt$rowsDispose("core:Basics.Int", $scope$221, $data$222, $slot$223) };
const DomSelectorNearMiss$p202 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $t$7 = $input$3.rows;
    const $t$9 = ($p$8) => $p$8.id;
    const $t$10 = $input$3.rows;
    const $t$12 = ($p$11) => $p$11.id;
    const $t$13 = $input$3.rows;
    const $t$14 = $input$3.rows;
    const $t$16 = ($p$15) => $p$15.id;
    const $made$17 = (($patch$29) => ({ m: ($item$18, $key$19, $position$20, $cx$26) => {
      const $r$27 = DomSelectorNearMiss$t68();
      const $w$28 = $r$27.firstChild;
      const $i$30 = { s: $r$27, q: Rt$empty, e: $r$27, x: undefined, y: $position$20, k: $key$19, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, $w0: $r$27, $w1: $w$28, $a0: undefined, $a1: undefined };
      $patch$29($i$30, $item$18, $position$20);
      $i$30.x = $item$18;
      return $i$30;
    }, p: $patch$29, r: DomSelectorNearMiss$domNoRestate, view: DomSelectorNearMiss$domRowView, item: DomSelectorNearMiss$domRowItem, sameItem: DomSelectorNearMiss$domRowSameItem, setItem: DomSelectorNearMiss$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelectorNearMiss$domSame12, remember: DomSelectorNearMiss$domRememberAll, probe: DomSelectorNearMiss$domNoProbe }))(($i$21, $item$22, $position$23) => {
      const $t$24 = $input$3.selected.$ === "Just" && $input$3.selected.a === $item$22.parent ? "on" : "";
      const $t$25 = $item$22.label;
      if ($t$24 !== $i$21.$a0) {
        $i$21.$w0.setAttribute("class", $t$24);
        $i$21.$a0 = $t$24;
      }
      if ($t$25 !== $i$21.$a1) {
        $i$21.$a1 = $t$25;
        $i$21.$w1.data = $t$25;
      }
      return $i$21;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.$c0, $t$4, $t$6, $made$17, [$input$3.selected], DomSelectorNearMiss$domSite12, $made$17);
    const $made$58 = (($patch$70) => ({ m: ($item$59, $key$60, $position$61, $cx$67) => {
      const $r$68 = DomSelectorNearMiss$t98();
      const $w$69 = $r$68.firstChild;
      const $i$71 = { s: $r$68, q: Rt$empty, e: $r$68, x: undefined, y: $position$61, k: $key$60, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, $w0: $r$68, $w1: $w$69, $a0: undefined, $a1: undefined };
      $patch$70($i$71, $item$59, $position$61);
      $i$71.x = $item$59;
      return $i$71;
    }, p: $patch$70, r: DomSelectorNearMiss$domNoRestate, view: DomSelectorNearMiss$domRowView, item: DomSelectorNearMiss$domRowItem, sameItem: DomSelectorNearMiss$domRowSameItem, setItem: DomSelectorNearMiss$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelectorNearMiss$domSame13, remember: DomSelectorNearMiss$domRememberAll, probe: DomSelectorNearMiss$domNoProbe }))(($i$62, $item$63, $position$64) => {
      const $t$65 = $input$3.selected.$ === "Just" && $input$3.selected.a === $item$63.id ? "on" : "";
      const $t$66 = Maybe$withDefault($input$3.selected, 0);
      if ($t$65 !== $i$62.$a0) {
        $i$62.$w0.setAttribute("class", $t$65);
        $i$62.$a0 = $t$65;
      }
      if ($t$66 !== $i$62.$a1) {
        $i$62.$a1 = $t$66;
        $i$62.$w1.data = $t$66;
      }
      return $i$62;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.$c1, $t$7, $t$9, $made$58, [$input$3.selected], DomSelectorNearMiss$domSite13, $made$58);
    const $made$90 = (($patch$102) => ({ m: ($item$91, $key$92, $position$93, $cx$99) => {
      const $r$100 = DomSelectorNearMiss$t127();
      const $w$101 = $r$100.firstChild;
      const $i$103 = { s: $r$100, q: Rt$empty, e: $r$100, x: undefined, y: $position$93, k: $key$92, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, $w0: $r$100, $w1: $w$101, $a0: undefined, $a1: undefined };
      $patch$102($i$103, $item$91, $position$93);
      $i$103.x = $item$91;
      return $i$103;
    }, p: $patch$102, r: DomSelectorNearMiss$domNoRestate, view: DomSelectorNearMiss$domRowView, item: DomSelectorNearMiss$domRowItem, sameItem: DomSelectorNearMiss$domRowSameItem, setItem: DomSelectorNearMiss$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelectorNearMiss$domSame14, remember: DomSelectorNearMiss$domRememberAll, probe: DomSelectorNearMiss$domNoProbe }))(($i$94, $item$95, $position$96) => {
      const sel$8 = $input$3.selected;
      const $t$97 = sel$8.$ === "Just" && sel$8.a === $item$95.id ? "on" : "";
      const $t$98 = $item$95.label;
      if ($t$97 !== $i$94.$a0) {
        $i$94.$w0.setAttribute("class", $t$97);
        $i$94.$a0 = $t$97;
      }
      if ($t$98 !== $i$94.$a1) {
        $i$94.$a1 = $t$98;
        $i$94.$w1.data = $t$98;
      }
      return $i$94;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.$c2, $t$10, $t$12, $made$90, [$input$3.selected], DomSelectorNearMiss$domSite14, $made$90);
    const $made$122 = (($patch$134) => ({ m: ($item$123, $key$124, $position$125, $cx$131) => {
      const $r$132 = DomSelectorNearMiss$t152();
      const $w$133 = $r$132.firstChild;
      const $i$135 = { s: $r$132, q: Rt$empty, e: $r$132, x: undefined, y: $position$125, k: $key$124, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, $w0: $r$132, $w1: $w$133, $a0: undefined, $a1: undefined };
      $patch$134($i$135, $item$123, $position$125);
      $i$135.x = $item$123;
      return $i$135;
    }, p: $patch$134, r: DomSelectorNearMiss$domNoRestate, view: DomSelectorNearMiss$domRowView, item: DomSelectorNearMiss$domRowItem, sameItem: DomSelectorNearMiss$domRowSameItem, setItem: DomSelectorNearMiss$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelectorNearMiss$domSame15, remember: DomSelectorNearMiss$domRememberAll, probe: DomSelectorNearMiss$domNoProbe }))(($i$126, $item$127, $position$128) => {
      const $t$129 = $input$3.selected.$ === "Just" && $input$3.selected.a === $item$127.id ? "on" : "";
      const $t$130 = $item$127.label;
      if ($t$129 !== $i$126.$a0) {
        $i$126.$w0.setAttribute("class", $t$129);
        $i$126.$a0 = $t$129;
      }
      if ($t$130 !== $i$126.$a1) {
        $i$126.$a1 = $t$130;
        $i$126.$w1.data = $t$130;
      }
      return $i$126;
    });
    Rt$forPosition($i$1.$c3, $t$13, $made$122, [$input$3.selected], DomSelectorNearMiss$domPositionSite, $made$122);
    const $made$154 = (($patch$166) => ({ m: ($item$155, $key$156, $position$157, $cx$163) => {
      const $r$164 = DomSelectorNearMiss$t200();
      const $w$165 = $r$164.firstChild;
      const $i$167 = { s: $r$164, q: Rt$empty, e: $r$164, x: undefined, y: $position$157, k: $key$156, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, $w0: $r$164, $w1: $w$165, $a0: undefined, $a1: undefined };
      $patch$166($i$167, $item$155, $position$157);
      $i$167.x = $item$155;
      return $i$167;
    }, p: $patch$166, r: DomSelectorNearMiss$domNoRestate, view: DomSelectorNearMiss$domRowView, item: DomSelectorNearMiss$domRowItem, sameItem: DomSelectorNearMiss$domRowSameItem, setItem: DomSelectorNearMiss$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelectorNearMiss$domSame17, remember: DomSelectorNearMiss$domRememberAll, probe: DomSelectorNearMiss$domNoProbe }))(($i$158, $item$159, $position$160) => {
      const $t$161 = DomSelectorNearMiss$isOn($input$3.selected, $item$159.id + 1);
      const $t$162 = $item$159.label;
      if ($t$161 !== $i$158.$a0) {
        $i$158.$w0.setAttribute("class", $t$161);
        $i$158.$a0 = $t$161;
      }
      if ($t$162 !== $i$158.$a1) {
        $i$158.$a1 = $t$162;
        $i$158.$w1.data = $t$162;
      }
      return $i$158;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.$c5, $t$14, $t$16, $made$154, [$input$3.selected], DomSelectorNearMiss$domSite17, $made$154);
  }
  {
    const $t$186 = $input$3.rows;
    const $t$188 = ($p$187) => $p$187.id;
    const $made$189 = (($patch$204) => ({ m: ($item$190, $key$191, $position$192, $cx$201) => {
      const $r$202 = DomSelectorNearMiss$t180();
      const $w$203 = $r$202.firstChild;
      const $i$205 = { s: $r$202, q: Rt$empty, e: $r$202, x: undefined, y: $position$192, k: $key$191, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, $w0: $r$202, $w1: $w$203, $a0: undefined, $a1: undefined };
      $patch$204($i$205, $item$190, $position$192);
      $i$205.x = $item$190;
      return $i$205;
    }, p: $patch$204, r: DomSelectorNearMiss$domNoRestate, view: DomSelectorNearMiss$domRowView, item: DomSelectorNearMiss$domRowItem, sameItem: DomSelectorNearMiss$domRowSameItem, setItem: DomSelectorNearMiss$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelectorNearMiss$domSameNever, remember: DomSelectorNearMiss$domRemember16, probe: DomSelectorNearMiss$domNoProbe }))(($i$193, $item$194, $position$195) => {
      const $t$199 = DomSelectorNearMiss$eq$r$at(($p$196, $p$197, $p$198) => Maybe$Maybe$$eq(DomSelectorNearMiss$eq$prim, $p$196, $p$197, $p$198), { at: { $: "Just", a: $item$194.id } }, $input$3.pick) ? "on" : "";
      const $t$200 = $item$194.label;
      if ($t$199 !== $i$193.$a0) {
        $i$193.$w0.setAttribute("class", $t$199);
        $i$193.$a0 = $t$199;
      }
      if ($t$200 !== $i$193.$a1) {
        $i$193.$a1 = $t$200;
        $i$193.$w1.data = $t$200;
      }
      return $i$193;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.$c4, $t$186, $t$188, $made$189, [$input$3.pick], DomSelectorNearMiss$domSite16, $made$189);
  }
  $i$1.$l = $i$1.$c0.w || $i$1.$c0.l || $i$1.$c1.w || $i$1.$c1.l || $i$1.$c2.w || $i$1.$c2.l || $i$1.$c3.w || $i$1.$c3.l || $i$1.$c4.w || $i$1.$c4.l || $i$1.$c5.w || $i$1.$c5.l;
};
const DomSelectorNearMiss$t202 = Rt$template("<div><!><!><!><!><!><!>");
const DomSelectorNearMiss$k202 = { m: ($v$225, $cx$226) => {
  const $r$227 = DomSelectorNearMiss$t202();
  const $w$228 = $r$227.firstChild;
  const $w$229 = $w$228.nextSibling;
  const $w$230 = $w$229.nextSibling;
  const $w$231 = $w$230.nextSibling;
  const $w$232 = $w$231.nextSibling;
  const $w$233 = $w$232.nextSibling;
  const $c$234 = Rt$slot($r$227, $w$228, $cx$226);
  const $c$235 = Rt$slot($r$227, $w$229, $cx$226);
  const $c$236 = Rt$slot($r$227, $w$230, $cx$226);
  const $c$237 = Rt$slot($r$227, $w$231, $cx$226);
  const $c$238 = Rt$slot($r$227, $w$232, $cx$226);
  const $c$239 = Rt$slot($r$227, $w$233, $cx$226);
  const $i$240 = { s: $r$227, q: Rt$empty, e: $r$227, $c0: $c$234, $c1: $c$235, $c2: $c$236, $c3: $c$237, $c4: $c$238, $c5: $c$239 };
  DomSelectorNearMiss$p202($i$240, $v$225);
  return $i$240;
}, p: DomSelectorNearMiss$p202, l: true };
const DomSelectorNearMiss$eq$prim = ($x, $y) => $x === $y;
const DomSelectorNearMiss$eq$r$at = ($m$0, $x, $y, $d = 0) => $d > 400 ? _derived$deep([$m$0, $x.at, $y.at], $d) : $m$0($x.at, $y.at, $d + 1);
const DomSelectorNearMiss$isOn = (selected$1, id$2) => selected$1.$ === "Just" && selected$1.a === id$2 ? "on" : "";
const DomSelectorNearMiss$table$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{pick={at=core:Maybe.Maybe(core:Basics.Int)},rows=core:List.List({id=core:Basics.Int,label=core:String.String,parent=core:Basics.Int}),selected=core:Maybe.Maybe(core:Basics.Int)}" + ")", a: undefined };
const DomSelectorNearMiss$table = ($m$0, model$1) => ({ t: DomSelectorNearMiss$k202, v: { ...DomSelectorNearMiss$table$$packet$1, a: model$1 } });
export { DomSelectorNearMiss$table };
//# sourceMappingURL=DomSelectorNearMiss.mjs.map
