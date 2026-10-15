import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$templateRowPush, Direct$visitObserve, Direct$templateRowPop, Direct$unset, Direct$visitFactory, Direct$insertText, Direct$visitRow, Direct$visitScope, Direct$groupOnce, Direct$keyMap, Direct$groupProgram, Direct$visitBegin, Direct$row, Direct$visitEnd, Direct$rekey, Direct$swap, Direct$append, Direct$prepend, Direct$clear, Direct$insert, Direct$removeAt, Direct$each, Direct$positional, Direct$on, Direct$delegate, Direct$wrong, Direct$same, Direct$verifyList, Direct$verify } from "./_platform/Direct.mjs";
import { List$update, List$set, List$swap, List$push, List$cons, List$insertAt, List$removeAt, List$reverse } from "./_core/List.mjs";
const ListScripts$fresh = (model$1, label$2) => ({ id: model$1.next, label: label$2 });
const ListScripts$main = Tea$sandbox(($root$1, $t$2) => {
  const $t$17 = [];
  const $t$18 = ["a", "b"];
  const init$19 = { mark: "", next: 0, plain: $t$18, rows: $t$17 };
  let $model$20 = init$19;
  $t$2.innerHTML = "<li><!><!>";
  const $T$21 = $t$2.content.firstChild;
  $t$2.innerHTML = "<li> ";
  const $T$22 = $t$2.content.firstChild;
  $t$2.innerHTML = "<main><button>edit</button><button>set</button><button>swap</button><button>append</button><button>prepend</button><button>clear</button><button>insert</button><button>remove</button><button>mark</button><button>reverse</button><ul></ul><ol>";
  const $r$23 = $t$2.content;
  const $w$24 = $r$23.firstChild;
  const $w$25 = $w$24.firstChild;
  const $w$26 = $w$25.nextSibling;
  const $w$27 = $w$26.nextSibling;
  const $w$28 = $w$27.nextSibling;
  const $w$29 = $w$28.nextSibling;
  const $w$30 = $w$29.nextSibling;
  const $w$31 = $w$30.nextSibling;
  const $w$32 = $w$31.nextSibling;
  const $w$33 = $w$32.nextSibling;
  const $w$34 = $w$33.nextSibling;
  const $w$35 = $w$34.nextSibling;
  const $w$36 = $w$35.nextSibling;
  const $g$37 = ($r$38) => {
    const $rowBefore$39 = Direct$templateRowPush($r$38);
    Direct$visitObserve($r$38, 0);
    const $it$40 = $r$38.it;
    const $t$41 = $it$40.label;
    if ($t$41 !== $r$38.s1) {
      $r$38.x1.data = $t$41;
      $r$38.s1 = $t$41;
    }
    Direct$templateRowPop($rowBefore$39);
  };
  const $g$42 = ($r$43) => {
    const $rowBefore$44 = Direct$templateRowPush($r$43);
    Direct$visitObserve($r$43, 1);
    const $it$45 = $r$43.it;
    const $t$46 = $model$20.mark;
    if ($t$46 !== $r$43.s2) {
      $r$43.x2.data = $t$46;
      $r$43.s2 = $t$46;
    }
    Direct$templateRowPop($rowBefore$44);
  };
  const $g$47 = ($r$48) => {
    const $rowBefore$49 = Direct$templateRowPush($r$48);
    Direct$visitObserve($r$48, 2);
    const $it$50 = $r$48.it;
    if ($it$50 !== $r$48.s0) {
      $r$48.w1.data = $it$50;
      $r$48.s0 = $it$50;
    }
    Direct$templateRowPop($rowBefore$49);
  };
  const $l$56 = ($e$51, $r$52) => {
    const $it$53 = $r$52.it;
    const $t$54 = $it$53.id;
    $hRemove$55($t$54);
  };
  const $make$63 = Direct$visitFactory(($it$57, $L$58, $j$59) => {
    const $e$60 = $T$22.cloneNode(true);
    const $w$61 = $e$60.firstChild;
    const $r$62 = { e: $e$60, it: $it$57, w1: $w$61, s0: Direct$unset };
    $e$60.$v = $L$58;
    $g$47($r$62);
    return $r$62;
  });
  const $make$73 = Direct$visitFactory(($it$64, $L$65, $j$66) => {
    const $e$67 = $T$21.cloneNode(true);
    const $w$68 = $e$67.firstChild;
    const $w$69 = $w$68.nextSibling;
    const $x$70 = Direct$insertText($e$67, $w$68, "");
    const $x$71 = Direct$insertText($e$67, $w$69, "");
    const $r$72 = { e: $e$67, it: $it$64, l: 0, x1: $x$70, x2: $x$71, s1: Direct$unset, s2: Direct$unset };
    $e$67.$r = $r$72;
    $e$67.$v = $L$65;
    $e$67.$click = $l$56;
    $g$37($r$72);
    $g$42($r$72);
    return $r$72;
  });
  const $W$75 = ($r$76) => {
    Direct$visitRow($r$76);
    Direct$visitScope($r$76, [[0, true], [1, true]]);
    if (Direct$groupOnce($r$76, 0)) {
      $g$37($r$76);
    }
    if (Direct$groupOnce($r$76, 1)) {
      $g$42($r$76);
    }
  };
  const $W$74 = ($r$77) => {
    Direct$visitRow($r$77);
    Direct$visitScope($r$77, [[2, true]]);
    if (Direct$groupOnce($r$77, 2)) {
      $g$47($r$77);
    }
  };
  const $t$80 = ($p$79) => $p$79.id;
  const $key$81 = $t$80;
  const $L$78 = { p: $w$35, n: null, r: [], m: $make$73, o: true, k: $key$81, u: null, w: $W$75, x: Direct$keyMap(), d: 0, z: Direct$unset, i: false };
  const $L$82 = { p: $w$36, n: null, r: [], m: $make$63, o: true, k: null, u: null, w: $W$74, x: null, d: null, z: Direct$unset, i: false };
  const $hEdit$90 = ($p$83, $p$84) => {
    Direct$groupProgram(null);
    const $visitBefore$85 = Direct$visitBegin($root$1, 0);
    const $k$86 = $p$83;
    $model$20 = { ...$model$20, rows: List$update($model$20.rows, $p$83, (r$25) => ({ ...r$25, label: $p$84 })) };
    Direct$visitScope($root$1, []);
    {
      const $t$87 = $model$20.rows;
      const $xs$88 = $t$87;
      {
        const $r$89 = Direct$row($L$78, $xs$88, $k$86);
        if ($r$89 !== null) {
          Direct$visitRow($r$89);
          Direct$visitScope($r$89, [[0, true], [1, false]]);
          if (Direct$groupOnce($r$89, 0)) {
            $g$37($r$89);
          }
        }
      }
    }
    Direct$visitEnd($visitBefore$85);
  };
  const $hSet$97 = ($p$91) => {
    Direct$groupProgram(null);
    const $visitBefore$92 = Direct$visitBegin($root$1, 1);
    const $k$93 = $p$91;
    $model$20 = { ...$model$20, rows: List$set($model$20.rows, $p$91, ListScripts$fresh($model$20, "set")), next: $model$20.next + 1 };
    Direct$visitScope($root$1, []);
    {
      const $t$94 = $model$20.rows;
      const $xs$95 = $t$94;
      {
        const $r$96 = Direct$rekey($L$78, $xs$95, $k$93);
        if ($r$96 !== null) {
          Direct$visitRow($r$96);
          Direct$visitScope($r$96, [[0, true], [1, false]]);
          if (Direct$groupOnce($r$96, 0)) {
            $g$37($r$96);
          }
        }
      }
    }
    Direct$visitEnd($visitBefore$92);
  };
  const $hSwap$105 = ($p$98, $p$99) => {
    Direct$groupProgram(null);
    const $visitBefore$100 = Direct$visitBegin($root$1, 2);
    const $k$101 = $p$98;
    const $k$102 = $p$99;
    $model$20 = { ...$model$20, rows: List$swap($model$20.rows, $p$98, $p$99) };
    Direct$visitScope($root$1, []);
    {
      const $t$103 = $model$20.rows;
      const $xs$104 = $t$103;
      Direct$swap($L$78, $xs$104, $k$101, $k$102);
    }
    Direct$visitEnd($visitBefore$100);
  };
  const $hAppend$109 = () => {
    Direct$groupProgram(null);
    const $visitBefore$106 = Direct$visitBegin($root$1, 3);
    $model$20 = { ...$model$20, rows: List$push($model$20.rows, ListScripts$fresh($model$20, "end")), next: $model$20.next + 1 };
    Direct$visitScope($root$1, []);
    {
      const $t$107 = $model$20.rows;
      const $xs$108 = $t$107;
      Direct$append($L$78, $xs$108);
    }
    Direct$visitEnd($visitBefore$106);
  };
  const $hPrepend$113 = () => {
    Direct$groupProgram(null);
    const $visitBefore$110 = Direct$visitBegin($root$1, 4);
    $model$20 = { ...$model$20, rows: List$cons(ListScripts$fresh($model$20, "front"), $model$20.rows), next: $model$20.next + 1 };
    Direct$visitScope($root$1, []);
    {
      const $t$111 = $model$20.rows;
      const $xs$112 = $t$111;
      Direct$prepend($L$78, $xs$112);
    }
    Direct$visitEnd($visitBefore$110);
  };
  const $hClear$117 = () => {
    Direct$groupProgram(null);
    const $visitBefore$114 = Direct$visitBegin($root$1, 5);
    $model$20 = { ...$model$20, rows: [] };
    Direct$visitScope($root$1, []);
    {
      const $t$115 = $model$20.rows;
      const $xs$116 = $t$115;
      Direct$clear($L$78);
    }
    Direct$visitEnd($visitBefore$114);
  };
  const $hInsert$123 = ($p$118) => {
    Direct$groupProgram(null);
    const $visitBefore$119 = Direct$visitBegin($root$1, 6);
    const $k$120 = $p$118;
    $model$20 = { ...$model$20, rows: List$insertAt($model$20.rows, $p$118, ListScripts$fresh($model$20, "in")), next: $model$20.next + 1 };
    Direct$visitScope($root$1, []);
    {
      const $t$121 = $model$20.rows;
      const $xs$122 = $t$121;
      Direct$insert($L$78, $xs$122, $k$120);
    }
    Direct$visitEnd($visitBefore$119);
  };
  const $hRemove$55 = ($p$124) => {
    Direct$groupProgram(null);
    const $visitBefore$125 = Direct$visitBegin($root$1, 7);
    const $k$126 = $p$124;
    $model$20 = { ...$model$20, rows: List$removeAt($model$20.rows, $p$124) };
    Direct$visitScope($root$1, []);
    {
      const $t$127 = $model$20.rows;
      const $xs$128 = $t$127;
      Direct$removeAt($L$78, $xs$128, $k$126);
    }
    Direct$visitEnd($visitBefore$125);
  };
  const $hMark$133 = () => {
    Direct$groupProgram(null);
    const $visitBefore$129 = Direct$visitBegin($root$1, 8);
    $model$20 = { ...$model$20, mark: `${$model$20.mark}*` };
    Direct$visitScope($root$1, []);
    {
      const $t$130 = $model$20.rows;
      const $xs$131 = $t$130;
      Direct$each($L$78, $xs$131, ($r$132) => {
        Direct$visitRow($r$132);
        Direct$visitScope($r$132, [[0, false], [1, true]]);
        if (Direct$groupOnce($r$132, 1)) {
          $g$42($r$132);
        }
      });
    }
    Direct$visitEnd($visitBefore$129);
  };
  const $hReverse$137 = () => {
    Direct$groupProgram(null);
    const $visitBefore$134 = Direct$visitBegin($root$1, 9);
    $model$20 = { ...$model$20, plain: List$reverse($model$20.plain) };
    Direct$visitScope($root$1, []);
    {
      const $t$135 = $model$20.plain;
      const $xs$136 = $t$135;
      Direct$positional($L$82, $xs$136, $W$74);
    }
    Direct$visitEnd($visitBefore$134);
  };
  {
    const $l$139 = ($e$138) => {
      $hEdit$90(1, "edited");
    };
    Direct$on($w$25, "click", $l$139);
    const $l$141 = ($e$140) => {
      $hSet$97(0);
    };
    Direct$on($w$26, "click", $l$141);
    const $l$143 = ($e$142) => {
      $hSwap$105(0, 2);
    };
    Direct$on($w$27, "click", $l$143);
    Direct$on($w$28, "click", $hAppend$109);
    Direct$on($w$29, "click", $hPrepend$113);
    Direct$on($w$30, "click", $hClear$117);
    const $l$148 = ($e$147) => {
      $hInsert$123(1);
    };
    Direct$on($w$31, "click", $l$148);
    const $l$150 = ($e$149) => {
      $hRemove$55(1);
    };
    Direct$on($w$32, "click", $l$150);
    Direct$on($w$33, "click", $hMark$133);
    Direct$on($w$34, "click", $hReverse$137);
  }
  Direct$delegate(0, $w$35, "click", "$click");
  {
    const $t$153 = $model$20.rows;
    const $xs$154 = $t$153;
    Direct$append($L$78, $xs$154);
  }
  {
    const $t$155 = $model$20.plain;
    const $xs$156 = $t$155;
    Direct$append($L$82, $xs$156);
  }
  $root$1.append($r$23);
  const $check$160 = ($r$157) => {
    const $it$159 = $r$157.it;
    if (!Direct$same($it$159, $r$157.s0)) {
      Direct$wrong("the text hole at ListScripts.beni:96:61", $r$157.s0, $it$159);
    }
    if ($r$157.w1.data !== `${$it$159}`) {
      Direct$wrong("the text hole at ListScripts.beni:96:61 in the document", $r$157.w1.data, `${$it$159}`);
    }
  };
  const $check$166 = ($r$161) => {
    const $it$163 = $r$161.it;
    const $t$164 = $it$163.label;
    const $t$165 = $model$20.mark;
    if (!Direct$same($t$164, $r$161.s1)) {
      Direct$wrong("the text hole at ListScripts.beni:92:49", $r$161.s1, $t$164);
    }
    if ($r$161.x1.data !== `${$t$164}`) {
      Direct$wrong("the text hole at ListScripts.beni:92:49 in the document", $r$161.x1.data, `${$t$164}`);
    }
    if (!Direct$same($t$165, $r$161.s2)) {
      Direct$wrong("the text hole at ListScripts.beni:92:58", $r$161.s2, $t$165);
    }
    if ($r$161.x2.data !== `${$t$165}`) {
      Direct$wrong("the text hole at ListScripts.beni:92:58 in the document", $r$161.x2.data, `${$t$165}`);
    }
  };
  Direct$verify(() => {
    {
      const $t$167 = $model$20.rows;
      const $xs$168 = $t$167;
      Direct$verifyList($L$78, $xs$168, $check$166, "the `For` at ListScripts.beni:91:14", false);
    }
    {
      const $t$169 = $model$20.plain;
      const $xs$170 = $t$169;
      Direct$verifyList($L$82, $xs$170, $check$160, "the `For` at ListScripts.beni:96:14", false);
    }
  });
});
export { ListScripts$main };
//# sourceMappingURL=ListScripts.mjs.map
