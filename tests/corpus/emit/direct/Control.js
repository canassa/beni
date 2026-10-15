import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$visitObserve, Direct$edited, Direct$control, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$visitEnd, Direct$on, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { String$length } from "./_core/String.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
const Control$main = Tea$sandbox(($root$1, $t$2) => {
  const $init$3 = { secret: false, text: "ab" };
  let $model$4 = $init$3;
  $t$2.innerHTML = "<main><button>toggle</button><input>";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild;
  const $w$8 = $w$7.nextSibling;
  let $s$9 = Direct$unset;
  let $s$10 = Direct$unset;
  const $g$11 = () => {
    Direct$visitObserve($root$1, 0);
    const $t$12 = $model$4.secret ? "password" : "text";
    if ($t$12 !== $s$9) {
      $w$8.setAttribute("type", $t$12);
      $s$9 = $t$12;
      Direct$edited($w$8);
    }
  };
  const $g$13 = () => {
    Direct$visitObserve($root$1, 1);
    const $t$14 = $model$4.text;
    if ($t$14 !== $s$10) {
      Direct$control($w$8, "value", $t$14);
      $s$10 = $t$14;
    }
  };
  const $hTyped$17 = ($p$15) => {
    Direct$groupProgram(null);
    const $visitBefore$16 = Direct$visitBegin($root$1, 0);
    $model$4 = String$length($p$15) > 3 ? $model$4 : { ...$model$4, text: $p$15 };
    Direct$visitScope($root$1, [[0, false], [1, true]]);
    $g$13();
    Direct$visitEnd($visitBefore$16);
  };
  const $hToggle$19 = () => {
    Direct$groupProgram(null);
    const $visitBefore$18 = Direct$visitBegin($root$1, 1);
    $model$4 = { ...$model$4, secret: !$model$4.secret };
    Direct$visitScope($root$1, [[0, true], [1, false]]);
    $g$11();
    Direct$visitEnd($visitBefore$18);
  };
  {
    Direct$on($w$7, "click", $hToggle$19);
    const $l$23 = ($e$21) => {
      const $payload$22 = Html$targetValue($e$21);
      $hTyped$17($payload$22);
    };
    Direct$on($w$8, "input", $l$23);
  }
  $g$11();
  $g$13();
  $root$1.append($r$5);
  Direct$verify(() => {
    const $t$24 = $model$4.secret ? "password" : "text";
    const $t$25 = $model$4.text;
    if (!Direct$same($t$24, $s$9)) {
      Direct$wrong("the attribute `type` at Control.beni:37:13", $s$9, $t$24);
    }
    if ($w$8.getAttribute("type") !== `${$t$24}`) {
      Direct$wrong("the attribute `type` at Control.beni:37:13 in the document", $w$8.getAttribute("type"), `${$t$24}`);
    }
    if (!Direct$same($t$25, $s$10)) {
      Direct$wrong("the attribute `value` at Control.beni:38:13", $s$10, $t$25);
    }
  });
});
export { Control$main };
//# sourceMappingURL=Control.mjs.map
