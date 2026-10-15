import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$visitObserve, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$visitEnd, Direct$on, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { String$fromInt } from "./_core/String.mjs";
const HoleHandler$main = Tea$sandbox(($root$1, $t$2) => {
  const $init$3 = { fixed: 7, tick: 0, title: "Holes" };
  let $model$4 = $init$3;
  $t$2.innerHTML = "<main><h1>Holes</h1><p> </p><button>tick</button><p> ";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild;
  const $w$8 = $w$7.firstChild;
  const $w$9 = $w$7.nextSibling;
  const $w$10 = $w$9.firstChild;
  const $w$11 = $w$9.nextSibling;
  const $w$12 = $w$11.nextSibling;
  const $w$13 = $w$12.firstChild;
  let $s$14 = Direct$unset;
  let $s$15 = Direct$unset;
  const $g$16 = () => {
    Direct$visitObserve($root$1, 1);
    const $t$17 = String$fromInt($model$4.tick);
    if ($t$17 !== $s$15) {
      $w$13.data = $t$17;
      $s$15 = $t$17;
    }
  };
  const $hany$20 = ($p$18) => {
    Direct$groupProgram(null);
    const $visitBefore$19 = Direct$visitBegin($root$1, 0);
    $model$4 = { ...$model$4, tick: $model$4.tick + 1 };
    Direct$visitScope($root$1, [[0, false], [1, true]]);
    $g$16();
    Direct$visitEnd($visitBefore$19);
  };
  {
    const $l$22 = ($e$21) => {
      $hany$20("Tick");
    };
    Direct$on($w$11, "click", $l$22);
  }
  {
    const $t$23 = String$fromInt($model$4.fixed);
    $w$10.data = $t$23;
    $s$14 = $t$23;
  }
  $g$16();
  $root$1.append($r$5);
  Direct$verify(() => {
    const $t$24 = $model$4.title;
    const $t$25 = String$fromInt($model$4.fixed);
    const $t$26 = String$fromInt($model$4.tick);
    if (!Direct$same($t$25, $s$14)) {
      Direct$wrong("the text hole at HoleHandler.beni:31:12", $s$14, $t$25);
    }
    if ($w$10.data !== `${$t$25}`) {
      Direct$wrong("the text hole at HoleHandler.beni:31:12 in the document", $w$10.data, `${$t$25}`);
    }
    if (!Direct$same($t$26, $s$15)) {
      Direct$wrong("the text hole at HoleHandler.beni:33:12", $s$15, $t$26);
    }
    if ($w$13.data !== `${$t$26}`) {
      Direct$wrong("the text hole at HoleHandler.beni:33:12 in the document", $w$13.data, `${$t$26}`);
    }
    if ($w$8.data !== `${$t$24}`) {
      Direct$wrong("the text HoleHandler.beni:30:13 baked into the page", $w$8.data, `${$t$24}`);
    }
  });
});
export { HoleHandler$main };
//# sourceMappingURL=HoleHandler.mjs.map
