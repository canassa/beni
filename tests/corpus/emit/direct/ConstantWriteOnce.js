import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$safeUrl, Direct$send, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { String$fromInt } from "./_core/String.mjs";
const ConstantWriteOnce$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = 0;
  let $model$4 = init$3;
  $t$2.innerHTML = "<main><button>inc</button><a>link";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild;
  const $w$8 = $w$7.nextSibling;
  let $s$9 = Direct$unset;
  let $s$10 = Direct$unset;
  let $s$11 = Direct$unset;
  const $g$12 = () => {
    const $t$13 = String$fromInt($model$4);
    const $t$14 = String$fromInt($model$4);
    if ($t$13 !== $s$9) {
      $w$8.setAttribute("title", $t$13);
      $s$9 = $t$13;
    }
    if ($s$10 === Direct$unset) {
      $s$10 = true;
      $w$8.setAttribute("href", Direct$safeUrl("é/x"));
    }
    if ($t$14 !== $s$11) {
      $w$8.setAttribute("lang", $t$14);
      $s$11 = $t$14;
    }
  };
  const $patchAll$15 = () => {
    $g$12();
  };
  const $hany$17 = ($p$16) => {
    $model$4 = $model$4 + 1;
    $patchAll$15();
  };
  {
    const $l$19 = ($e$18) => {
      $hany$17("Inc");
    };
    $w$7.addEventListener("click", ($e$20) => {
      Direct$send($l$19, $e$20);
    });
  }
  $g$12();
  $root$1.append($r$5);
  Direct$verify(() => {
    const $t$21 = String$fromInt($model$4);
    const $t$22 = String$fromInt($model$4);
    if (!Direct$same($t$21, $s$9)) {
      Direct$wrong("the attribute `title` at ConstantWriteOnce.beni:21:12", $s$9, $t$21);
    }
    if ($w$8.getAttribute("title") !== `${$t$21}`) {
      Direct$wrong("the attribute `title` at ConstantWriteOnce.beni:21:12 in the document", $w$8.getAttribute("title"), `${$t$21}`);
    }
    if (!Direct$same($t$22, $s$11)) {
      Direct$wrong("the attribute `lang` at ConstantWriteOnce.beni:21:48", $s$11, $t$22);
    }
    if ($w$8.getAttribute("lang") !== `${$t$22}`) {
      Direct$wrong("the attribute `lang` at ConstantWriteOnce.beni:21:48 in the document", $w$8.getAttribute("lang"), `${$t$22}`);
    }
  });
});
export { ConstantWriteOnce$main };
//# sourceMappingURL=ConstantWriteOnce.mjs.map
