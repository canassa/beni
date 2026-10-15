import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$visitObserve, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$visitEnd, Direct$on, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
const GateUnderMap$main = Tea$sandbox(($root$1, $t$2) => {
  const $init$3 = { a: "a", b: "b", c: "c" };
  let $model$4 = $init$3;
  $t$2.innerHTML = "<main><button>set</button><span class=\"chip chip-large chip-outlined chip-with-a-long-class-list\"><b> </b><i> </i><u> </u><em> </em></span><div><span class=\"chip chip-large chip-outlined chip-with-a-long-class-list\"><b> </b><i> </i><u> </u><em> ";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild;
  const $w$8 = $w$7.nextSibling;
  const $w$9 = $w$8.firstChild;
  const $w$10 = $w$9.firstChild;
  const $w$11 = $w$9.nextSibling;
  const $w$12 = $w$11.firstChild;
  const $w$13 = $w$11.nextSibling;
  const $w$14 = $w$13.firstChild;
  const $w$15 = $w$13.nextSibling;
  const $w$16 = $w$15.firstChild;
  const $w$17 = $w$8.nextSibling;
  const $w$18 = $w$17.firstChild;
  const $w$19 = $w$18.firstChild;
  const $w$20 = $w$19.firstChild;
  const $w$21 = $w$19.nextSibling;
  const $w$22 = $w$21.firstChild;
  const $w$23 = $w$21.nextSibling;
  const $w$24 = $w$23.firstChild;
  const $w$25 = $w$23.nextSibling;
  const $w$26 = $w$25.firstChild;
  let $s$27 = Direct$unset;
  let $s$28 = Direct$unset;
  let $s$29 = Direct$unset;
  let $s$30 = Direct$unset;
  let $s$31 = Direct$unset;
  let $s$32 = Direct$unset;
  let $s$33 = Direct$unset;
  let $s$34 = Direct$unset;
  const $g$35 = () => {
    Direct$visitObserve($root$1, 0);
    const $t$36 = $model$4.a;
    if ($t$36 !== $s$27) {
      $w$10.data = $t$36;
      $s$27 = $t$36;
    }
    if ($t$36 !== $s$28) {
      $w$12.data = $t$36;
      $s$28 = $t$36;
    }
    if ($t$36 !== $s$29) {
      $w$14.data = $t$36;
      $s$29 = $t$36;
    }
    if ($t$36 !== $s$30) {
      $w$16.data = $t$36;
      $s$30 = $t$36;
    }
  };
  const $g$37 = () => {
    Direct$visitObserve($root$1, 1);
    const $t$38 = $model$4.b;
    if ($t$38 !== $s$31) {
      $w$20.data = $t$38;
      $s$31 = $t$38;
    }
    if ($t$38 !== $s$32) {
      $w$22.data = $t$38;
      $s$32 = $t$38;
    }
    if ($t$38 !== $s$33) {
      $w$24.data = $t$38;
      $s$33 = $t$38;
    }
    if ($t$38 !== $s$34) {
      $w$26.data = $t$38;
      $s$34 = $t$38;
    }
  };
  const $hSet$41 = ($p$39) => {
    Direct$groupProgram(null);
    const $visitBefore$40 = Direct$visitBegin($root$1, 0);
    $model$4 = { ...$model$4, a: $p$39 };
    Direct$visitScope($root$1, [[0, true], [1, false], [2, false]]);
    $g$35();
    Direct$visitEnd($visitBefore$40);
  };
  const $hInner$44 = ($p$42) => {
    Direct$groupProgram(null);
    const $visitBefore$43 = Direct$visitBegin($root$1, 1);
    $model$4 = undefined;
    Direct$visitScope($root$1, [[0, false], [1, true], [2, false]]);
    $g$37();
    Direct$visitEnd($visitBefore$43);
  };
  {
    const $l$46 = ($e$45) => {
      $hSet$41("x");
    };
    Direct$on($w$7, "click", $l$46);
  }
  $g$35();
  $g$37();
  {
  }
  $root$1.append($r$5);
  Direct$verify(() => {
    {
      const $t$47 = $model$4.a;
      if (!Direct$same($t$47, $s$27)) {
        Direct$wrong("the text hole at GateUnderMap.beni:26:12", $s$27, $t$47);
      }
      if ($w$10.data !== `${$t$47}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:26:12 in the document", $w$10.data, `${$t$47}`);
      }
      if (!Direct$same($t$47, $s$28)) {
        Direct$wrong("the text hole at GateUnderMap.beni:27:12", $s$28, $t$47);
      }
      if ($w$12.data !== `${$t$47}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:27:12 in the document", $w$12.data, `${$t$47}`);
      }
      if (!Direct$same($t$47, $s$29)) {
        Direct$wrong("the text hole at GateUnderMap.beni:28:12", $s$29, $t$47);
      }
      if ($w$14.data !== `${$t$47}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:28:12 in the document", $w$14.data, `${$t$47}`);
      }
      if (!Direct$same($t$47, $s$30)) {
        Direct$wrong("the text hole at GateUnderMap.beni:29:13", $s$30, $t$47);
      }
      if ($w$16.data !== `${$t$47}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:29:13 in the document", $w$16.data, `${$t$47}`);
      }
    }
    {
      const $t$48 = $model$4.b;
      if (!Direct$same($t$48, $s$31)) {
        Direct$wrong("the text hole at GateUnderMap.beni:26:12", $s$31, $t$48);
      }
      if ($w$20.data !== `${$t$48}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:26:12 in the document", $w$20.data, `${$t$48}`);
      }
      if (!Direct$same($t$48, $s$32)) {
        Direct$wrong("the text hole at GateUnderMap.beni:27:12", $s$32, $t$48);
      }
      if ($w$22.data !== `${$t$48}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:27:12 in the document", $w$22.data, `${$t$48}`);
      }
      if (!Direct$same($t$48, $s$33)) {
        Direct$wrong("the text hole at GateUnderMap.beni:28:12", $s$33, $t$48);
      }
      if ($w$24.data !== `${$t$48}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:28:12 in the document", $w$24.data, `${$t$48}`);
      }
      if (!Direct$same($t$48, $s$34)) {
        Direct$wrong("the text hole at GateUnderMap.beni:29:13", $s$34, $t$48);
      }
      if ($w$26.data !== `${$t$48}`) {
        Direct$wrong("the text hole at GateUnderMap.beni:29:13 in the document", $w$26.data, `${$t$48}`);
      }
    }
  });
});
export { GateUnderMap$main };
//# sourceMappingURL=GateUnderMap.mjs.map
