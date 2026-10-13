import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$on, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { List$push, List$sum } from "./_core/List.mjs";
const DerivedValue$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { items: [1, 2], ticks: 0 };
  let $model$4 = init$3;
  let $d$5 = Direct$unset;
  $t$2.innerHTML = "<main><button>tick</button><button>add</button><p> </p><p> ";
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
    const $t$17 = $model$4.ticks;
    if ($t$17 !== $s$14) {
      $w$11.data = $t$17;
      $s$14 = $t$17;
    }
  };
  const $g$18 = () => {
    if ($d$5 !== $s$15) {
      $w$13.data = $d$5;
      $s$15 = $d$5;
    }
  };
  const $hTick$19 = () => {
    $model$4 = { ...$model$4, ticks: $model$4.ticks + 1 };
    $g$16();
  };
  const $hAdd$21 = () => {
    $model$4 = { ...$model$4, items: List$push($model$4.items, $model$4.items.length) };
    {
      const $t$20 = List$sum($model$4.items);
      $d$5 = $t$20;
    }
    $g$18();
  };
  {
    Direct$on($w$8, "click", $hTick$19);
    Direct$on($w$9, "click", $hAdd$21);
  }
  {
    const $t$24 = List$sum($model$4.items);
    $d$5 = $t$24;
  }
  $g$16();
  $g$18();
  $root$1.append($r$6);
  Direct$verify(() => {
    {
      const $t$25 = List$sum($model$4.items);
      if (!Direct$same($t$25, $d$5)) {
        Direct$wrong("the derived value `let` 0 of `view`", $d$5, $t$25);
      }
    }
    const $t$26 = $model$4.ticks;
    if (!Direct$same($t$26, $s$14)) {
      Direct$wrong("the text hole at DerivedValue.beni:38:12", $s$14, $t$26);
    }
    if ($w$11.data !== `${$t$26}`) {
      Direct$wrong("the text hole at DerivedValue.beni:38:12 in the document", $w$11.data, `${$t$26}`);
    }
    if (!Direct$same($d$5, $s$15)) {
      Direct$wrong("the text hole at DerivedValue.beni:39:12", $s$15, $d$5);
    }
    if ($w$13.data !== `${$d$5}`) {
      Direct$wrong("the text hole at DerivedValue.beni:39:12 in the document", $w$13.data, `${$d$5}`);
    }
  });
});
export { DerivedValue$main };
//# sourceMappingURL=DerivedValue.mjs.map
