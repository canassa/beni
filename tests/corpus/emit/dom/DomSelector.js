import { Rt$template, Rt$delegate, Rt$empty, Rt$forKeyed, Rt$rowsHead, Rt$rowsTail, Rt$rowsRestate, Rt$rowsDispose, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomSelector$t83 = Rt$template("<p> ");
const DomSelector$domNoRestate = ($value$27) => {
};
const DomSelector$domRowView = ($value$28) => $value$28;
const DomSelector$domRowItem = ($value$29) => $value$29.x;
const DomSelector$domRowSameItem = ($value$30, $value$31) => $value$30.x === $value$31;
const DomSelector$domRowSetItem = ($value$32, $value$33) => {
  $value$32.x = $value$33;
};
const DomSelector$domSame11 = ($was$34, $now$35) => $was$34 !== Rt$empty;
const DomSelector$domRememberAll = ($value$36) => $value$36;
const DomSelector$domProbe1 = ($inputs$37) => $inputs$37[1];
const DomSelector$domSite11 = { head: ($scope$38, $data$39, $slot$40) => Rt$rowsHead("core:Basics.Int", $scope$38, $data$39, $slot$40), tail: ($scope$42, $data$43, $slot$44) => Rt$rowsTail("core:Basics.Int", $scope$42, $data$43, $slot$44), restate: ($scope$46, $data$47, $slot$48, $stamp$49) => Rt$rowsRestate("core:Basics.Int", $scope$46, $data$47, $slot$48, $stamp$49), dispose: ($scope$50, $data$51, $slot$52) => Rt$rowsDispose("core:Basics.Int", $scope$50, $data$51, $slot$52) };
const DomSelector$t108 = Rt$template("<p> ");
const DomSelector$domSame12 = ($was$67, $now$68) => $was$67 !== Rt$empty;
const DomSelector$domSite12 = { head: ($scope$69, $data$70, $slot$71) => Rt$rowsHead("core:Basics.Int", $scope$69, $data$70, $slot$71), tail: ($scope$73, $data$74, $slot$75) => Rt$rowsTail("core:Basics.Int", $scope$73, $data$74, $slot$75), restate: ($scope$77, $data$78, $slot$79, $stamp$80) => Rt$rowsRestate("core:Basics.Int", $scope$77, $data$78, $slot$79, $stamp$80), dispose: ($scope$81, $data$82, $slot$83) => Rt$rowsDispose("core:Basics.Int", $scope$81, $data$82, $slot$83) };
const DomSelector$t171 = Rt$template("<p> ");
const DomSelector$domSame15 = ($was$99, $now$100) => $was$99 !== Rt$empty;
const DomSelector$domSite15 = { head: ($scope$101, $data$102, $slot$103) => Rt$rowsHead("core:Basics.Int", $scope$101, $data$102, $slot$103), tail: ($scope$105, $data$106, $slot$107) => Rt$rowsTail("core:Basics.Int", $scope$105, $data$106, $slot$107), restate: ($scope$109, $data$110, $slot$111, $stamp$112) => Rt$rowsRestate("core:Basics.Int", $scope$109, $data$110, $slot$111, $stamp$112), dispose: ($scope$113, $data$114, $slot$115) => Rt$rowsDispose("core:Basics.Int", $scope$113, $data$114, $slot$115) };
const DomSelector$t127 = Rt$template("<p> ");
const DomSelector$domSame13 = ($was$131, $now$132) => $was$131 !== Rt$empty;
const DomSelector$domKeyIdentity = ($value$133) => $value$133;
const DomSelector$domSite13 = { head: ($scope$134, $data$135, $slot$136) => Rt$rowsHead("core:Basics.Int", $scope$134, $data$135, $slot$136), tail: ($scope$138, $data$139, $slot$140) => Rt$rowsTail("core:Basics.Int", $scope$138, $data$139, $slot$140), restate: ($scope$142, $data$143, $slot$144, $stamp$145) => Rt$rowsRestate("core:Basics.Int", $scope$142, $data$143, $slot$144, $stamp$145), dispose: ($scope$146, $data$147, $slot$148) => Rt$rowsDispose("core:Basics.Int", $scope$146, $data$147, $slot$148) };
const DomSelector$t154 = Rt$template("<p><b> ");
const DomSelector$domSame14 = ($was$169, $now$170) => $was$169 !== Rt$empty && $was$169[0] === $now$170[0];
const DomSelector$domProbe2 = ($inputs$171) => $inputs$171[2];
const DomSelector$domSite14 = { head: ($scope$172, $data$173, $slot$174) => Rt$rowsHead("core:Basics.Int", $scope$172, $data$173, $slot$174), tail: ($scope$176, $data$177, $slot$178) => Rt$rowsTail("core:Basics.Int", $scope$176, $data$177, $slot$178), restate: ($scope$180, $data$181, $slot$182, $stamp$183) => Rt$rowsRestate("core:Basics.Int", $scope$180, $data$181, $slot$182, $stamp$183), dispose: ($scope$184, $data$185, $slot$186) => Rt$rowsDispose("core:Basics.Int", $scope$184, $data$185, $slot$186) };
const DomSelector$p173 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $t$7 = $input$3.rows;
    const $t$8 = (r$4) => r$4.id;
    const $t$9 = $input$3.rows;
    const $t$11 = ($p$10) => $p$10.id;
    const $made$12 = (($patch$25) => ({ m: ($item$13, $key$14, $position$15, $cx$22) => {
      const $r$23 = DomSelector$t83();
      const $w$24 = $r$23.firstChild;
      Rt$delegate(["click"]);
      if ($cx$22 !== null) {
        $r$23.$$cx = $cx$22;
      }
      const $i$26 = { s: $r$23, q: Rt$empty, e: $r$23, x: undefined, y: $position$15, k: $key$14, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$23, w1: $w$24, a0: undefined, a1: undefined, a2: undefined };
      $patch$25($i$26, $item$13, $position$15);
      $i$26.x = $item$13;
      return $i$26;
    }, p: $patch$25, r: DomSelector$domNoRestate, view: DomSelector$domRowView, item: DomSelector$domRowItem, sameItem: DomSelector$domRowSameItem, setItem: DomSelector$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelector$domSame11, remember: DomSelector$domRememberAll, probe: DomSelector$domProbe1 }))(($i$16, $item$17, $position$18) => {
      const $t$19 = DomSelector$rowClass($input$3, $item$17);
      const $t$20 = { $: "Select", a: $item$17.id };
      const $t$21 = $item$17.label;
      if ($t$19 !== $i$16.a0) {
        $i$16.w0.setAttribute("class", $t$19);
        $i$16.a0 = $t$19;
      }
      if ($t$20 !== $i$16.a1) {
        $i$16.a1 = $t$20;
        $i$16.w0.$$click = $t$20;
      }
      if ($t$21 !== $i$16.a2) {
        $i$16.a2 = $t$21;
        $i$16.w1.data = $t$21;
      }
      return $i$16;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.c0, $t$4, $t$6, $made$12, [$input$3.selected, $input$3.selected.$ === "Just" ? $input$3.selected.a : $input$3.selected], DomSelector$domSite11, $made$12);
    const $made$54 = (($patch$65) => ({ m: ($item$55, $key$56, $position$57, $cx$62) => {
      const $r$63 = DomSelector$t108();
      const $w$64 = $r$63.firstChild;
      const $i$66 = { s: $r$63, q: Rt$empty, e: $r$63, x: undefined, y: $position$57, k: $key$56, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$63, w1: $w$64, a0: undefined, a1: undefined };
      $patch$65($i$66, $item$55, $position$57);
      $i$66.x = $item$55;
      return $i$66;
    }, p: $patch$65, r: DomSelector$domNoRestate, view: DomSelector$domRowView, item: DomSelector$domRowItem, sameItem: DomSelector$domRowSameItem, setItem: DomSelector$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelector$domSame12, remember: DomSelector$domRememberAll, probe: DomSelector$domProbe1 }))(($i$58, $item$59, $position$60) => {
      const id$5 = $item$59.id;
      const label$6 = $item$59.label;
      const $t$61 = $input$3.selected.$ === "Just" && $input$3.selected.a === id$5 ? "on" : "";
      if ($t$61 !== $i$58.a0) {
        $i$58.w0.setAttribute("class", $t$61);
        $i$58.a0 = $t$61;
      }
      if (label$6 !== $i$58.a1) {
        $i$58.a1 = label$6;
        $i$58.w1.data = label$6;
      }
      return $i$58;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.c1, $t$7, $t$8, $made$54, [$input$3.selected, $input$3.selected.$ === "Just" ? $input$3.selected.a : $input$3.selected], DomSelector$domSite12, $made$54);
    const $made$85 = (($patch$97) => ({ m: ($item$86, $key$87, $position$88, $cx$94) => {
      const $r$95 = DomSelector$t171();
      const $w$96 = $r$95.firstChild;
      const $i$98 = { s: $r$95, q: Rt$empty, e: $r$95, x: undefined, y: $position$88, k: $key$87, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$95, w1: $w$96, a0: undefined, a1: undefined };
      $patch$97($i$98, $item$86, $position$88);
      $i$98.x = $item$86;
      return $i$98;
    }, p: $patch$97, r: DomSelector$domNoRestate, view: DomSelector$domRowView, item: DomSelector$domRowItem, sameItem: DomSelector$domRowSameItem, setItem: DomSelector$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelector$domSame15, remember: DomSelector$domRememberAll, probe: DomSelector$domProbe1 }))(($i$89, $item$90, $position$91) => {
      const $t$92 = DomSelector$isOn($input$3.selected, $item$90.id);
      const $t$93 = $item$90.label;
      if ($t$92 !== $i$89.a0) {
        $i$89.w0.setAttribute("class", $t$92);
        $i$89.a0 = $t$92;
      }
      if ($t$93 !== $i$89.a1) {
        $i$89.a1 = $t$93;
        $i$89.w1.data = $t$93;
      }
      return $i$89;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.c4, $t$9, $t$11, $made$85, [$input$3.selected, $input$3.selected.$ === "Just" ? $input$3.selected.a : $input$3.selected], DomSelector$domSite15, $made$85);
  }
  {
    const $t$117 = $input$3.ids;
    const $made$118 = (($patch$129) => ({ m: ($item$119, $key$120, $position$121, $cx$126) => {
      const $r$127 = DomSelector$t127();
      const $w$128 = $r$127.firstChild;
      const $i$130 = { s: $r$127, q: Rt$empty, e: $r$127, x: undefined, y: $position$121, k: $key$120, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$127, w1: $w$128, a0: undefined, a1: undefined };
      $patch$129($i$130, $item$119, $position$121);
      $i$130.x = $item$119;
      return $i$130;
    }, p: $patch$129, r: DomSelector$domNoRestate, view: DomSelector$domRowView, item: DomSelector$domRowItem, sameItem: DomSelector$domRowSameItem, setItem: DomSelector$domRowSetItem, o: true, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelector$domSame13, remember: DomSelector$domRememberAll, probe: DomSelector$domProbe1 }))(($i$122, $item$123, $position$124) => {
      const $t$125 = $item$123 !== $input$3.cursor ? "" : "at";
      if ($t$125 !== $i$122.a0) {
        $i$122.w0.setAttribute("class", $t$125);
        $i$122.a0 = $t$125;
      }
      if ($item$123 !== $i$122.x) {
        if ($item$123 !== $i$122.a1) {
          $i$122.a1 = $item$123;
          $i$122.w1.data = $item$123;
        }
      }
      return $i$122;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.c2, $t$117, DomSelector$domKeyIdentity, $made$118, [$input$3.cursor, $input$3.cursor], DomSelector$domSite13, $made$118);
  }
  {
    const $t$150 = $input$3.rows;
    const $t$152 = ($p$151) => $p$151.id;
    const $made$153 = (($patch$167) => ({ m: ($item$154, $key$155, $position$156, $cx$163) => {
      const $r$164 = DomSelector$t154();
      const $w$165 = $r$164.firstChild;
      const $w$166 = $w$165.firstChild;
      const $i$168 = { s: $r$164, q: Rt$empty, e: $r$164, x: undefined, y: $position$156, k: $key$155, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$164, w1: $w$165, w2: $w$166, a0: undefined, a1: undefined, a2: undefined };
      $patch$167($i$168, $item$154, $position$156);
      $i$168.x = $item$154;
      return $i$168;
    }, p: $patch$167, r: DomSelector$domNoRestate, view: DomSelector$domRowView, item: DomSelector$domRowItem, sameItem: DomSelector$domRowSameItem, setItem: DomSelector$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSelector$domSame14, remember: DomSelector$domRememberAll, probe: DomSelector$domProbe2 }))(($i$157, $item$158, $position$159) => {
      const $t$160 = $input$3.theme;
      const $t$161 = $input$3.cursor === $item$158.id ? "at" : "";
      const $t$162 = $item$158.label;
      if ($t$160 !== $i$157.a0) {
        $i$157.w0.setAttribute("class", $t$160);
        $i$157.a0 = $t$160;
      }
      if ($t$161 !== $i$157.a1) {
        $i$157.w1.setAttribute("class", $t$161);
        $i$157.a1 = $t$161;
      }
      if ($t$162 !== $i$157.a2) {
        $i$157.a2 = $t$162;
        $i$157.w2.data = $t$162;
      }
      return $i$157;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.c3, $t$150, $t$152, $made$153, [$input$3.theme, $input$3.cursor, $input$3.cursor], DomSelector$domSite14, $made$153);
  }
  $i$1.$l = $i$1.c0.w || $i$1.c0.l || $i$1.c1.w || $i$1.c1.l || $i$1.c2.w || $i$1.c2.l || $i$1.c3.w || $i$1.c3.l || $i$1.c4.w || $i$1.c4.l;
};
const DomSelector$t173 = Rt$template("<div><!><!><!><!><!>");
const DomSelector$k173 = { m: ($v$188, $cx$189) => {
  const $r$190 = DomSelector$t173();
  const $w$191 = $r$190.firstChild;
  const $w$192 = $w$191.nextSibling;
  const $w$193 = $w$192.nextSibling;
  const $w$194 = $w$193.nextSibling;
  const $w$195 = $w$194.nextSibling;
  const $c$196 = Rt$slot($r$190, $w$191, $cx$189);
  const $c$197 = Rt$slot($r$190, $w$192, $cx$189);
  const $c$198 = Rt$slot($r$190, $w$193, $cx$189);
  const $c$199 = Rt$slot($r$190, $w$194, $cx$189);
  const $c$200 = Rt$slot($r$190, $w$195, $cx$189);
  const $i$201 = { s: $r$190, q: Rt$empty, e: $r$190, c0: $c$196, c1: $c$197, c2: $c$198, c3: $c$199, c4: $c$200 };
  DomSelector$p173($i$201, $v$188);
  return $i$201;
}, p: DomSelector$p173, l: true };
const DomSelector$Msg$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const DomSelector$Msg$$eq = ($x, $y) => $x.a === $y.a;
const DomSelector$rowClass = (model$1, row$2) => model$1.selected.$ === "Just" && model$1.selected.a === row$2.id ? "danger" : "";
const DomSelector$isOn = (selected$1, id$2) => selected$1.$ === "Just" && selected$1.a === id$2 ? "on" : "";
const DomSelector$table$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{cursor=core:Basics.Int,ids=core:List.List(core:Basics.Int),rows=core:List.List({id=core:Basics.Int,label=core:String.String}),selected=core:Maybe.Maybe(core:Basics.Int),theme=core:String.String}" + ")", a: undefined };
const DomSelector$table = (model$1) => ({ t: DomSelector$k173, v: { ...DomSelector$table$$packet$1, a: model$1 } });
export { DomSelector$Msg$$compare, DomSelector$Msg$$eq, DomSelector$table };
//# sourceMappingURL=DomSelector.mjs.map
