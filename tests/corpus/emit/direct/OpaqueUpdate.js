import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$visitObserve, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$visitEnd, Direct$on, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { Debug$logAs } from "./_core/Debug.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
const OpaqueUpdate$withLogging = (f$1) => (msg$2, model$3) => f$1(msg$2, model$3);
const OpaqueUpdate$update = (msg$1, model$2) => {
  if (msg$1.$ === "Inc") {
    return { ...model$2, n: model$2.n + 1 };
  } else {
    const s$3 = msg$1.a;
    return { ...model$2, text: s$3 };
  }
};
const OpaqueUpdate$main = Tea$sandbox(($root$1, $t$2) => {
  const $init$3 = { n: 0, text: "" };
  let $model$4 = $init$3;
  const $update$5 = OpaqueUpdate$withLogging(OpaqueUpdate$update);
  $t$2.innerHTML = "<main><button id=inc>inc</button><input id=in><p id=n> </p><p id=text> ";
  const $r$6 = $t$2.content;
  const $w$7 = $r$6.firstChild;
  const $w$8 = $w$7.firstChild;
  const $w$9 = $w$8.nextSibling;
  const $w$10 = $w$9.nextSibling;
  const $w$11 = $w$10.firstChild;
  const $w$12 = $w$10.nextSibling;
  const $w$13 = $w$12.firstChild;
  let $s$14 = Direct$unset;
  let $s$15 = Direct$unset;
  const $g$16 = () => {
    Direct$visitObserve($root$1, 0);
    const $t$17 = Debug$logAs("[\"i\",[]]", "n", $model$4.n);
    if ($t$17 !== $s$14) {
      $w$11.data = $t$17;
      $s$14 = $t$17;
    }
  };
  const $g$18 = () => {
    Direct$visitObserve($root$1, 1);
    const $t$19 = $model$4.text;
    if ($t$19 !== $s$15) {
      $w$13.data = $t$19;
      $s$15 = $t$19;
    }
  };
  const $patchAll$20 = () => {
    $g$16();
    $g$18();
  };
  const $hAll$23 = ($p$21) => {
    Direct$groupProgram(null);
    const $visitBefore$22 = Direct$visitBegin($root$1, 0);
    $model$4 = $update$5($p$21, $model$4);
    Direct$visitScope($root$1, [[0, true], [1, true]]);
    $patchAll$20();
    Direct$visitEnd($visitBefore$22);
  };
  {
    const $l$25 = ($e$24) => {
      $hAll$23({ $: "Inc", a: null });
    };
    Direct$on($w$8, "click", $l$25);
    const $l$28 = ($e$26) => {
      const $payload$27 = Html$targetValue($e$26);
      $hAll$23({ $: "Typed", a: $payload$27 });
    };
    Direct$on($w$9, "input", $l$28);
  }
  $g$16();
  $g$18();
  $root$1.append($r$6);
  Direct$verify(() => {
    const $t$29 = $model$4.text;
    if (!Direct$same($t$29, $s$15)) {
      Direct$wrong("the text hole at OpaqueUpdate.beni:40:22", $s$15, $t$29);
    }
    if ($w$13.data !== `${$t$29}`) {
      Direct$wrong("the text hole at OpaqueUpdate.beni:40:22 in the document", $w$13.data, `${$t$29}`);
    }
  });
});
export { OpaqueUpdate$main };
//# sourceMappingURL=OpaqueUpdate.mjs.map
