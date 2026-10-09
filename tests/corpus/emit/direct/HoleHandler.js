import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$send, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { String$fromInt } from "./_core/String.mjs";
const HoleHandler$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { fixed: 7, tick: 0, title: "Holes" };
  let $model$4 = init$3;
  $t$2.innerHTML = "<main><h1>Holes</h1><p> </p><button>tick</button><p> ";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild.nextSibling;
  const $w$8 = $w$7.firstChild;
  const $w$9 = $w$7.nextSibling;
  const $w$10 = $w$9.nextSibling;
  const $w$11 = $w$10.firstChild;
  let $s$12 = Direct$unset;
  let $s$13 = Direct$unset;
  const $g$14 = () => {
    const $t$15 = String$fromInt($model$4.tick);
    if ($t$15 !== $s$13) {
      $w$11.data = $t$15;
      $s$13 = $t$15;
    }
  };
  const $hany$17 = ($p$16) => {
    $model$4 = { ...$model$4, tick: $model$4.tick + 1 };
    $g$14();
  };
  {
    const $l$19 = ($e$18) => {
      $hany$17("Tick");
    };
    $w$9.addEventListener("click", ($e$20) => {
      Direct$send($l$19, $e$20);
    });
  }
  {
    const $t$21 = String$fromInt($model$4.fixed);
    $w$8.data = $t$21;
    $s$12 = $t$21;
  }
  $g$14();
  $root$1.append($r$5);
  Direct$verify(() => {
    const $t$22 = $model$4.title;
    const $t$23 = String$fromInt($model$4.fixed);
    const $t$24 = String$fromInt($model$4.tick);
    if (!Direct$same($t$23, $s$12)) {
      Direct$wrong("the text hole at HoleHandler.beni:31:12", $s$12, $t$23);
    }
    if (!Direct$same($t$24, $s$13)) {
      Direct$wrong("the text hole at HoleHandler.beni:33:12", $s$13, $t$24);
    }
    if (`${$t$22}` !== "Holes") {
      Direct$wrong("the text HoleHandler.beni:30:13 baked into the page", "Holes", `${$t$22}`);
    }
  });
});
export { HoleHandler$main };
//# sourceMappingURL=HoleHandler.mjs.map
