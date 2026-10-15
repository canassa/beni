import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$slot, Direct$unset, Direct$visitObserve, Direct$templateGroup, Direct$templateObserve, Direct$templatePatch, Direct$template, Direct$listen, Direct$templateCapture, Direct$templateInputs, Direct$templateValue, Direct$childList, Direct$templatePlace, Direct$childMaybe, Direct$visitFactory, Direct$templatePlan, Direct$groupProgram, Direct$visitBegin, Direct$templateProgram, Direct$visitScope, Direct$templateEnd, Direct$visitEnd, Direct$on, Direct$append, Direct$verifySlot, Direct$wrong, Direct$same, Direct$verifyList, Direct$verify } from "./_platform/Direct.mjs";
import { List$map, List$push } from "./_core/List.mjs";
import { Maybe$map } from "./_core/Maybe.mjs";
const ValueSlot$Add = { $: "Add", a: null };
const ValueSlot$dg65_0 = [[], false, true, true];
const ValueSlot$dp65_0 = ($i$20, $v$21) => {
  const $input$22 = $v$21[0];
  {
    if ($i$20.g0 === undefined) {
      $i$20.g0 = true;
      if (ValueSlot$Add !== $i$20.a0) {
        $i$20.a0 = ValueSlot$Add;
        $i$20.w0.$$click = ValueSlot$Add;
      }
    }
  }
};
const ValueSlot$dg65_1 = [["0:143"], false, false, false];
const ValueSlot$dp65_1 = ($i$20, $v$21) => {
  const $input$22 = $v$21[0];
  Direct$templateObserve($i$20, ValueSlot$dg65_1);
  {
    const $x$23 = $input$22;
    if ($x$23 !== $i$20.g1_0) {
      $i$20.g1_0 = $x$23;
      $i$20.w1.data = $x$23;
    }
  }
};
const ValueSlot$p65 = Direct$templatePatch(($i$20, $v$21) => {
  const $input$22 = $v$21[0];
  return $v$21;
}, ($i$20, $v$21) => {
  const $input$22 = $v$21[0];
}, 1, [Direct$templateGroup(ValueSlot$dg65_0, ValueSlot$dp65_0, null), Direct$templateGroup(ValueSlot$dg65_1, ValueSlot$dp65_1, null)], false);
const ValueSlot$t65 = Direct$template("<li> ", 0);
const ValueSlot$k65 = { m: ($v$24, $cx$25) => {
  const $r$26 = ValueSlot$t65();
  const $w$27 = $r$26.firstChild;
  Direct$listen($r$26, "click", 0);
  if ($cx$25 !== null) {
    $r$26.$$cx = $cx$25;
  }
  const $i$28 = { s: $r$26, q: null, e: $r$26, w0: $r$26, w1: $w$27, a0: undefined, g0: undefined, g1_0: NaN };
  ValueSlot$p65($i$28, $v$24);
  return $i$28;
}, p: ValueSlot$p65 };
const ValueSlot$dg84_0 = [[], false, true, false];
const ValueSlot$dp84_0 = ($i$37, $v$38) => {
  const $input$39 = $v$38[0];
  const $input$40 = $v$38[1];
  {
    const $x$41 = $input$39.id;
    if ($x$41 !== $i$37.g0_0) {
      $i$37.g0_0 = $x$41;
      const $t$42 = { $: "Pick", a: $input$39.id };
      if ($t$42 !== $i$37.a0) {
        $i$37.a0 = $t$42;
        $i$37.w0.$$click = $t$42;
      }
    }
  }
};
const ValueSlot$dg84_1 = [["0:197"], false, false, false];
const ValueSlot$dp84_1 = ($i$37, $v$38) => {
  const $input$39 = $v$38[0];
  const $input$40 = $v$38[1];
  Direct$templateObserve($i$37, ValueSlot$dg84_1);
  {
    const $x$43 = $input$40;
    if ($x$43 !== $i$37.g1_0) {
      $i$37.g1_0 = $x$43;
      $i$37.w1.data = $x$43;
    }
  }
};
const ValueSlot$p84 = Direct$templatePatch(($i$37, $v$38) => {
  const $input$39 = $v$38[0];
  const $input$40 = $v$38[1];
  return $v$38;
}, ($i$37, $v$38) => {
  const $input$39 = $v$38[0];
  const $input$40 = $v$38[1];
}, 2, [Direct$templateGroup(ValueSlot$dg84_0, ValueSlot$dp84_0, null), Direct$templateGroup(ValueSlot$dg84_1, ValueSlot$dp84_1, null)], false);
const ValueSlot$t84 = Direct$template("<b> ", 0);
const ValueSlot$k84 = { m: ($v$44, $cx$45) => {
  const $r$46 = ValueSlot$t84();
  const $w$47 = $r$46.firstChild;
  Direct$listen($r$46, "click", 0);
  if ($cx$45 !== null) {
    $r$46.$$cx = $cx$45;
  }
  const $i$48 = { s: $r$46, q: null, e: $r$46, w0: $r$46, w1: $w$47, a0: undefined, g0_0: NaN, g1_0: NaN };
  ValueSlot$p84($i$48, $v$44);
  return $i$48;
}, p: ValueSlot$p84 };
const ValueSlot$main = Tea$sandbox(($root$1, $t$2) => {
  const $t$4 = ["a"];
  const $t$5 = [{ id: 1, note: { $: "Just", a: "x" } }];
  const $init$6 = { names: $t$4, picked: 0, rows: $t$5, ticks: 0 };
  let $model$7 = $init$6;
  $t$2.innerHTML = "<li>";
  const $T$8 = $t$2.content.firstChild;
  $t$2.innerHTML = "<main><button> </button><ul></ul><ol>";
  const $r$9 = $t$2.content;
  const $w$10 = $r$9.firstChild;
  const $w$11 = $w$10.firstChild;
  const $w$12 = $w$11.firstChild;
  const $w$13 = $w$11.nextSibling;
  const $w$14 = $w$13.nextSibling;
  const $c$15 = Direct$slot($w$13, null, null);
  let $s$16 = Direct$unset;
  const $g$17 = () => {
    Direct$visitObserve($root$1, 0);
    const $t$18 = $model$7.ticks;
    if ($t$18 !== $s$16) {
      $w$12.data = $t$18;
      $s$16 = $t$18;
    }
  };
  const $g$19 = () => {
    Direct$visitObserve($root$1, 1);
    const $t$29 = Direct$templateValue("/0:128", () => List$map($model$7.names, (n$7) => ({ t: ValueSlot$k65, v: Direct$templateInputs([n$7], Direct$templateCapture("", "0:135")) })));
    Direct$templatePlace("/0:128", () => Direct$childList($c$15, $t$29));
  };
  const $make$50 = Direct$visitFactory(($it$30, $L$31, $j$32) => {
    const $e$33 = $T$8.cloneNode(true);
    const $c$34 = Direct$slot($e$33, null, null);
    const $r$35 = { e: $e$33, it: $it$30, c0: $c$34 };
    $e$33.$v = $L$31;
    {
      const $it$36 = $r$35.it;
      const $t$49 = Direct$templateValue("/0:180", () => Maybe$map($it$36.note, (s$15) => ({ t: ValueSlot$k84, v: Direct$templateInputs([$it$36, s$15], Direct$templateCapture("", "0:187")) })));
      Direct$templatePlace("/0:180", () => Direct$childMaybe($r$35.c0, $t$49.a));
    }
    return $r$35;
  });
  const $t$53 = ($p$52) => $p$52.id;
  const $key$54 = $t$53;
  const $L$51 = { p: $w$14, n: null, r: [], m: $make$50, o: true, k: $key$54, u: null, w: null, x: null, d: null, z: Direct$unset, i: false };
  const $templatePlan$55 = Direct$templatePlan([["$root", "110"], ["0:117", "010"], ["0:128", "100"], ["$call/0:128", "100"], ["0:143/0:128", "100"], ["0:159", "000"], ["0:180", "000"], ["$call/0:180", "000"], ["0:197/0:180", "000"], ["$producer/0:159", "000"], ["$value/0:135", "List Html uses value reconciliation without a row edit plan"]]);
  const $hAdd$58 = () => {
    Direct$groupProgram(null);
    const $visitBefore$56 = Direct$visitBegin($templatePlan$55, 0);
    $model$7 = { ...$model$7, names: List$push($model$7.names, "n") };
    const $templateBefore$57 = Direct$templateProgram($templatePlan$55, 0);
    Direct$visitScope($root$1, [[0, false], [1, true]]);
    $g$19();
    Direct$templateEnd($templateBefore$57);
    Direct$visitEnd($visitBefore$56);
  };
  const $hTick$61 = () => {
    Direct$groupProgram(null);
    const $visitBefore$59 = Direct$visitBegin($templatePlan$55, 1);
    $model$7 = { ...$model$7, ticks: $model$7.ticks + 1 };
    const $templateBefore$60 = Direct$templateProgram($templatePlan$55, 1);
    Direct$visitScope($root$1, [[0, true], [1, false]]);
    $g$17();
    Direct$templateEnd($templateBefore$60);
    Direct$visitEnd($visitBefore$59);
  };
  const $hPick$65 = ($p$62) => {
    Direct$groupProgram(null);
    const $visitBefore$63 = Direct$visitBegin($templatePlan$55, 2);
    $model$7 = { ...$model$7, picked: $p$62 };
    const $templateBefore$64 = Direct$templateProgram($templatePlan$55, 2);
    Direct$visitScope($root$1, [[0, false], [1, false]]);
    Direct$templateEnd($templateBefore$64);
    Direct$visitEnd($visitBefore$63);
  };
  const $dispatch$67 = ($msg$68) => {
    if ($msg$68.$ === "Add") {
      $hAdd$58();
      return;
    }
    if ($msg$68.$ === "Tick") {
      $hTick$61();
      return;
    }
    $hPick$65($msg$68.a);
    return;
  };
  $root$1.$$root = $dispatch$67;
  {
    Direct$on($w$11, "click", $hTick$61);
  }
  const $templateBefore$69 = Direct$templateProgram($templatePlan$55, -1);
  $g$17();
  $g$19();
  {
    const $t$70 = $model$7.rows;
    const $xs$71 = $t$70;
    Direct$append($L$51, $xs$71);
  }
  $root$1.append($r$9);
  const $check$76 = ($r$72) => {
    {
      const $it$74 = $r$72.it;
      const $t$75 = Direct$templateValue("/0:180", () => Maybe$map($it$74.note, (s$44) => ({ t: ValueSlot$k84, v: Direct$templateInputs([$it$74, s$44], Direct$templateCapture("", "0:187")) })));
      Direct$verifySlot($r$72.c0, $t$75.a, 1, "the markup at ValueSlot.beni:53:27");
    }
  };
  Direct$verify(() => {
    const $t$77 = $model$7.ticks;
    if (!Direct$same($t$77, $s$16)) {
      Direct$wrong("the text hole at ValueSlot.beni:49:32", $s$16, $t$77);
    }
    if ($w$12.data !== `${$t$77}`) {
      Direct$wrong("the text hole at ValueSlot.beni:49:32 in the document", $w$12.data, `${$t$77}`);
    }
    {
      const $t$78 = Direct$templateValue("/0:128", () => List$map($model$7.names, (n$56) => ({ t: ValueSlot$k65, v: Direct$templateInputs([n$56], Direct$templateCapture("", "0:135")) })));
      Direct$verifySlot($c$15, $t$78, 2, "the markup at ValueSlot.beni:50:13");
    }
    {
      const $t$79 = $model$7.rows;
      const $xs$80 = $t$79;
      Direct$verifyList($L$51, $xs$80, $check$76, "the `For` at ValueSlot.beni:52:14", false);
    }
  });
  Direct$templateEnd($templateBefore$69);
});
export { ValueSlot$main };
//# sourceMappingURL=ValueSlot.mjs.map
