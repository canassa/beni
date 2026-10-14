import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$slot, Direct$unset, Direct$template, Direct$listen, Direct$childList, Direct$childMaybe, Direct$on, Direct$append, Direct$verifySlot, Direct$wrong, Direct$same, Direct$verifyList, Direct$verify } from "./_platform/Direct.mjs";
import { List$map, List$push } from "./_core/List.mjs";
import { Maybe$map } from "./_core/Maybe.mjs";
const ValueSlot$Add = { $: "Add", a: null };
const ValueSlot$p65 = (i$20, v$21) => {
  const $in$22 = v$21[0];
  if (i$20.g0 === undefined) {
    i$20.g0 = true;
    if (ValueSlot$Add !== i$20.a0) {
      i$20.a0 = ValueSlot$Add;
      i$20.w0.$$click = ValueSlot$Add;
    }
  }
  const x$23 = $in$22;
  if (x$23 !== i$20.g1_0) {
    i$20.g1_0 = x$23;
    i$20.w1.data = x$23;
  }
};
const ValueSlot$t65 = Direct$template("<li> ", 0);
const ValueSlot$k65 = { m: (v$24, cx$25) => {
  const r$26 = ValueSlot$t65();
  const w$27 = r$26.firstChild;
  Direct$listen(r$26, "click", 0);
  if (cx$25 !== null) {
    r$26.$$cx = cx$25;
  }
  const i$28 = { s: r$26, q: null, e: r$26, w0: r$26, w1: w$27, a0: undefined, g0: undefined, g1_0: NaN };
  ValueSlot$p65(i$28, v$24);
  return i$28;
}, p: ValueSlot$p65 };
const ValueSlot$p84 = (i$37, v$38) => {
  const $in$39 = v$38[0];
  const $in$40 = v$38[1];
  const x$41 = $in$39.id;
  if (x$41 !== i$37.g0_0) {
    i$37.g0_0 = x$41;
    const $t$42 = { $: "Pick", a: $in$39.id };
    if ($t$42 !== i$37.a0) {
      i$37.a0 = $t$42;
      i$37.w0.$$click = $t$42;
    }
  }
  const x$43 = $in$40;
  if (x$43 !== i$37.g1_0) {
    i$37.g1_0 = x$43;
    i$37.w1.data = x$43;
  }
};
const ValueSlot$t84 = Direct$template("<b> ", 0);
const ValueSlot$k84 = { m: (v$44, cx$45) => {
  const r$46 = ValueSlot$t84();
  const w$47 = r$46.firstChild;
  Direct$listen(r$46, "click", 0);
  if (cx$45 !== null) {
    r$46.$$cx = cx$45;
  }
  const i$48 = { s: r$46, q: null, e: r$46, w0: r$46, w1: w$47, a0: undefined, g0_0: NaN, g1_0: NaN };
  ValueSlot$p84(i$48, v$44);
  return i$48;
}, p: ValueSlot$p84 };
const ValueSlot$main = Tea$sandbox(($root$1, $t$2) => {
  const $t$4 = ["a"];
  const $t$5 = [{ id: 1, note: { $: "Just", a: "x" } }];
  const init$6 = { names: $t$4, picked: 0, rows: $t$5, ticks: 0 };
  let $model$7 = init$6;
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
    const $t$18 = $model$7.ticks;
    if ($t$18 !== $s$16) {
      $w$12.data = $t$18;
      $s$16 = $t$18;
    }
  };
  const $g$19 = () => {
    const $t$29 = List$map($model$7.names, (n$7) => ({ t: ValueSlot$k65, v: [n$7] }));
    Direct$childList($c$15, $t$29);
  };
  const $make$50 = ($it$30, $L$31, $j$32) => {
    const $e$33 = $T$8.cloneNode(true);
    const $c$34 = Direct$slot($e$33, null, null);
    const $r$35 = { e: $e$33, it: $it$30, c0: $c$34 };
    $e$33.$v = $L$31;
    {
      const $it$36 = $r$35.it;
      const $t$49 = Maybe$map($it$36.note, (s$15) => ({ t: ValueSlot$k84, v: [$it$36, s$15] }));
      Direct$childMaybe($r$35.c0, $t$49.a);
    }
    return $r$35;
  };
  const $t$53 = ($p$52) => $p$52.id;
  const $key$54 = $t$53;
  const $L$51 = { p: $w$14, n: null, r: [], m: $make$50, o: true, k: $key$54, u: null, w: null, x: null, d: null, z: Direct$unset, i: false };
  const $hAdd$55 = () => {
    $model$7 = { ...$model$7, names: List$push($model$7.names, "n") };
    $g$19();
  };
  const $hTick$56 = () => {
    $model$7 = { ...$model$7, ticks: $model$7.ticks + 1 };
    $g$17();
  };
  const $hPick$58 = ($p$57) => {
    $model$7 = { ...$model$7, picked: $p$57 };
  };
  const $dispatch$60 = ($msg$61) => {
    if ($msg$61.$ === "Add") {
      $hAdd$55();
      return;
    }
    if ($msg$61.$ === "Tick") {
      $hTick$56();
      return;
    }
    $hPick$58($msg$61.a);
  };
  $root$1.$$root = $dispatch$60;
  {
    Direct$on($w$11, "click", $hTick$56);
  }
  $g$17();
  $g$19();
  {
    const $t$62 = $model$7.rows;
    const $xs$63 = $t$62;
    Direct$append($L$51, $xs$63);
  }
  $root$1.append($r$9);
  const $check$68 = ($r$64) => {
    {
      const $it$66 = $r$64.it;
      const $t$67 = Maybe$map($it$66.note, (s$44) => ({ t: ValueSlot$k84, v: [$it$66, s$44] }));
      Direct$verifySlot($r$64.c0, $t$67.a, 1, "the markup at ValueSlot.beni:53:27");
    }
  };
  Direct$verify(() => {
    const $t$69 = $model$7.ticks;
    if (!Direct$same($t$69, $s$16)) {
      Direct$wrong("the text hole at ValueSlot.beni:49:32", $s$16, $t$69);
    }
    if ($w$12.data !== `${$t$69}`) {
      Direct$wrong("the text hole at ValueSlot.beni:49:32 in the document", $w$12.data, `${$t$69}`);
    }
    {
      const $t$70 = List$map($model$7.names, (n$56) => ({ t: ValueSlot$k65, v: [n$56] }));
      Direct$verifySlot($c$15, $t$70, 2, "the markup at ValueSlot.beni:50:13");
    }
    {
      const $t$71 = $model$7.rows;
      const $xs$72 = $t$71;
      Direct$verifyList($L$51, $xs$72, $check$68, "the `For` at ValueSlot.beni:52:14", false);
    }
  });
});
export { ValueSlot$main };
//# sourceMappingURL=ValueSlot.mjs.map
