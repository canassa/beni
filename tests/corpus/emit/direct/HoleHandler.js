import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$send, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { String$fromInt } from "./_core/String.mjs";
const HoleHandler$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { fixed: 7, tick: 0, title: "Holes" };
  let $model$4 = init$3;
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
    const $t$17 = String$fromInt($model$4.tick);
    if ($t$17 !== $s$15) {
      $w$13.data = $t$17;
      $s$15 = $t$17;
    }
  };
  const $hany$19 = ($p$18) => {
    $model$4 = { ...$model$4, tick: $model$4.tick + 1 };
    $g$16();
  };
  {
    const $l$21 = ($e$20) => {
      $hany$19("Tick");
    };
    $w$11.addEventListener("click", ($e$22) => {
      Direct$send($l$21, $e$22);
    });
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
