import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$insertText, Direct$unset, Direct$visitObserve, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$visitEnd, Direct$on, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
const DispatchPrefixes$Clear = { $: "Clear", a: null };
const DispatchPrefixes$apply = (msg$1, n$2) => {
  switch (msg$1.$) {
    case "Add":
      {
        const x$3 = msg$1.a;
        return n$2 + x$3;
      }
    case "Sub":
      {
        const x$4 = msg$1.a;
        return n$2 - x$4;
      }
    default:
      {
        return 0;
      }
  }
};
const DispatchPrefixes$update = (msg$1, model$2) => {
  switch (msg$1.$) {
    case "Left":
      {
        const inner$3 = msg$1.a;
        return { ...model$2, left: DispatchPrefixes$apply(inner$3, model$2.left) };
      }
    case "Right":
      {
        const inner$4 = msg$1.a;
        return { ...model$2, right: DispatchPrefixes$apply(inner$4, model$2.right) };
      }
    default:
      {
        return model$2;
      }
  }
};
const DispatchPrefixes$main = Tea$sandbox(($root$1, $t$2) => {
  const $init$3 = { left: 0, right: 0 };
  let $model$4 = $init$3;
  const $update$5 = DispatchPrefixes$update;
  $t$2.innerHTML = "<main><button id=la>left add</button><button id=ls>left sub</button><button id=lc>left clear</button><button id=ra>right add</button><button id=rs>right sub</button><button id=rc>right clear</button><button id=q>quiet</button><p>:<!>";
  const $r$6 = $t$2.content;
  const $w$7 = $r$6.firstChild;
  const $w$8 = $w$7.firstChild;
  const $w$9 = $w$8.nextSibling;
  const $w$10 = $w$9.nextSibling;
  const $w$11 = $w$10.nextSibling;
  const $w$12 = $w$11.nextSibling;
  const $w$13 = $w$12.nextSibling;
  const $w$14 = $w$13.nextSibling;
  const $w$15 = $w$14.nextSibling;
  const $w$16 = $w$15.firstChild;
  const $w$17 = $w$16.nextSibling;
  const $x$18 = Direct$insertText($w$15, $w$16, "");
  const $x$19 = Direct$insertText($w$15, $w$17, "");
  let $s$20 = Direct$unset;
  let $s$21 = Direct$unset;
  const $g$22 = () => {
    Direct$visitObserve($root$1, 0);
    const $t$23 = $model$4.left;
    if ($t$23 !== $s$20) {
      $x$18.data = $t$23;
      $s$20 = $t$23;
    }
  };
  const $g$24 = () => {
    Direct$visitObserve($root$1, 1);
    const $t$25 = $model$4.right;
    if ($t$25 !== $s$21) {
      $x$19.data = $t$25;
      $s$21 = $t$25;
    }
  };
  const $hLeft$Add$28 = ($p$26) => {
    Direct$groupProgram(null);
    const $visitBefore$27 = Direct$visitBegin($root$1, 0);
    $model$4 = $update$5($p$26, $model$4);
    Direct$visitScope($root$1, [[0, true], [1, false]]);
    $g$22();
    Direct$visitEnd($visitBefore$27);
  };
  const $hLeft$Sub$31 = ($p$29) => {
    Direct$groupProgram(null);
    const $visitBefore$30 = Direct$visitBegin($root$1, 1);
    $model$4 = $update$5($p$29, $model$4);
    Direct$visitScope($root$1, [[0, true], [1, false]]);
    $g$22();
    Direct$visitEnd($visitBefore$30);
  };
  const $hLeft$Clear$34 = ($p$32) => {
    Direct$groupProgram(null);
    const $visitBefore$33 = Direct$visitBegin($root$1, 2);
    $model$4 = $update$5($p$32, $model$4);
    Direct$visitScope($root$1, [[0, true], [1, false]]);
    $g$22();
    Direct$visitEnd($visitBefore$33);
  };
  const $hRight$Add$37 = ($p$35) => {
    Direct$groupProgram(null);
    const $visitBefore$36 = Direct$visitBegin($root$1, 3);
    $model$4 = $update$5($p$35, $model$4);
    Direct$visitScope($root$1, [[0, false], [1, true]]);
    $g$24();
    Direct$visitEnd($visitBefore$36);
  };
  const $hRight$Sub$40 = ($p$38) => {
    Direct$groupProgram(null);
    const $visitBefore$39 = Direct$visitBegin($root$1, 4);
    $model$4 = $update$5($p$38, $model$4);
    Direct$visitScope($root$1, [[0, false], [1, true]]);
    $g$24();
    Direct$visitEnd($visitBefore$39);
  };
  const $hRight$Clear$43 = ($p$41) => {
    Direct$groupProgram(null);
    const $visitBefore$42 = Direct$visitBegin($root$1, 5);
    $model$4 = $update$5($p$41, $model$4);
    Direct$visitScope($root$1, [[0, false], [1, true]]);
    $g$24();
    Direct$visitEnd($visitBefore$42);
  };
  const $h_$46 = ($p$44) => {
    Direct$groupProgram(null);
    const $visitBefore$45 = Direct$visitBegin($root$1, 6);
    $model$4 = $update$5($p$44, $model$4);
    Direct$visitScope($root$1, [[0, false], [1, false]]);
    Direct$visitEnd($visitBefore$45);
  };
  const $dispatch$48 = ($msg$62) => {
    if ($msg$62.$ === "Left") {
      if ($msg$62.a.$ === "Add") {
        $hLeft$Add$28($msg$62);
        return;
      }
      if ($msg$62.a.$ === "Sub") {
        $hLeft$Sub$31($msg$62);
        return;
      }
      if ($msg$62.a.$ === "Clear") {
        $hLeft$Clear$34($msg$62);
        return;
      }
    }
    if ($msg$62.$ === "Right") {
      if ($msg$62.a.$ === "Add") {
        $hRight$Add$37($msg$62);
        return;
      }
      if ($msg$62.a.$ === "Sub") {
        $hRight$Sub$40($msg$62);
        return;
      }
      if ($msg$62.a.$ === "Clear") {
        $hRight$Clear$43($msg$62);
        return;
      }
    }
    $h_$46($msg$62);
    return;
  };
  {
    const $l$49 = ($e$47) => {
      $dispatch$48({ $: "Left", a: { $: "Add", a: 2 } });
    };
    Direct$on($w$8, "click", $l$49);
    const $l$51 = ($e$50) => {
      $dispatch$48({ $: "Left", a: { $: "Sub", a: 1 } });
    };
    Direct$on($w$9, "click", $l$51);
    const $l$53 = ($e$52) => {
      $dispatch$48({ $: "Left", a: DispatchPrefixes$Clear });
    };
    Direct$on($w$10, "click", $l$53);
    const $l$55 = ($e$54) => {
      $dispatch$48({ $: "Right", a: { $: "Add", a: 3 } });
    };
    Direct$on($w$11, "click", $l$55);
    const $l$57 = ($e$56) => {
      $dispatch$48({ $: "Right", a: { $: "Sub", a: 2 } });
    };
    Direct$on($w$12, "click", $l$57);
    const $l$59 = ($e$58) => {
      $dispatch$48({ $: "Right", a: DispatchPrefixes$Clear });
    };
    Direct$on($w$13, "click", $l$59);
    const $l$61 = ($e$60) => {
      $h_$46({ $: "Quiet", a: null });
    };
    Direct$on($w$14, "click", $l$61);
  }
  $g$22();
  $g$24();
  $root$1.append($r$6);
  Direct$verify(() => {
    const $t$63 = $model$4.left;
    const $t$64 = $model$4.right;
    if (!Direct$same($t$63, $s$20)) {
      Direct$wrong("the text hole at DispatchPrefixes.beni:56:12", $s$20, $t$63);
    }
    if ($x$18.data !== `${$t$63}`) {
      Direct$wrong("the text hole at DispatchPrefixes.beni:56:12 in the document", $x$18.data, `${$t$63}`);
    }
    if (!Direct$same($t$64, $s$21)) {
      Direct$wrong("the text hole at DispatchPrefixes.beni:56:25", $s$21, $t$64);
    }
    if ($x$19.data !== `${$t$64}`) {
      Direct$wrong("the text hole at DispatchPrefixes.beni:56:25 in the document", $x$19.data, `${$t$64}`);
    }
  });
});
export { DispatchPrefixes$main };
//# sourceMappingURL=DispatchPrefixes.mjs.map
