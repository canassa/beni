import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$send, Direct$identity, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { String$fromInt } from "./_core/String.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
const MessageKeys$A = { $: "A", a: null };
const MessageKeys$Clicked = { $: "Clicked", a: null };
const MessageKeys$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { clicks: 0, sub: 0, text: "" };
  let $model$4 = init$3;
  $t$2.innerHTML = "<main><input id=in><p id=text> </p><p id=clicks> </p><button id=click>click</button><button id=a>a</button><button id=b>b</button><p id=sub> ";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild;
  const $w$8 = $w$7.nextSibling;
  const $w$9 = $w$8.firstChild;
  const $w$10 = $w$8.nextSibling;
  const $w$11 = $w$10.firstChild;
  const $w$12 = $w$10.nextSibling;
  const $w$13 = $w$12.nextSibling;
  const $w$14 = $w$13.nextSibling;
  const $w$15 = $w$14.nextSibling;
  const $w$16 = $w$15.firstChild;
  let $s$17 = Direct$unset;
  let $s$18 = Direct$unset;
  let $s$19 = Direct$unset;
  let $s$20 = Direct$unset;
  const $g$21 = () => {
    const $t$22 = $model$4.text;
    if ($t$22 !== $s$17) {
      $w$9.data = $t$22;
      $s$17 = $t$22;
    }
  };
  const $g$23 = () => {
    const $t$24 = $model$4.clicks > 1 ? "many" : "few";
    const $t$25 = String$fromInt($model$4.clicks);
    if ($t$24 !== $s$18) {
      $w$10.setAttribute("class", $t$24);
      $s$18 = $t$24;
    }
    if ($t$25 !== $s$19) {
      $w$11.data = $t$25;
      $s$19 = $t$25;
    }
  };
  const $g$26 = () => {
    const $t$27 = String$fromInt($model$4.sub);
    if ($t$27 !== $s$20) {
      $w$16.data = $t$27;
      $s$20 = $t$27;
    }
  };
  const $hTyped$29 = ($p$28) => {
    $model$4 = { ...$model$4, text: $p$28 };
    $g$21();
  };
  const $hClicked$30 = () => {
    $model$4 = { ...$model$4, clicks: $model$4.clicks + 1 };
    $g$23();
  };
  const $hNested$A$33 = ($p$31) => {
    const sub$17 = $p$31.a;
    let $t$32;
    if (sub$17.$ === "A") {
      $t$32 = { ...$model$4, sub: $model$4.sub + 1 };
    } else {
      const n$18 = sub$17.a;
      $t$32 = { ...$model$4, sub: n$18 };
    }
    $model$4 = $t$32;
    $g$26();
  };
  const $hNested$B$36 = ($p$34) => {
    const sub$22 = $p$34.a;
    let $t$35;
    if (sub$22.$ === "A") {
      $t$35 = { ...$model$4, sub: $model$4.sub + 1 };
    } else {
      const n$23 = sub$22.a;
      $t$35 = { ...$model$4, sub: n$23 };
    }
    $model$4 = $t$35;
    $g$26();
  };
  const $dispatch$44 = ($msg$53) => {
    if ($msg$53.$ === "Typed") {
      $hTyped$29($msg$53.a);
      return;
    }
    if ($msg$53.$ === "Clicked") {
      $hClicked$30();
      return;
    }
    if ($msg$53.$ === "Nested" && $msg$53.a.$ === "A") {
      $hNested$A$33($msg$53);
      return;
    }
    $hNested$B$36($msg$53);
  };
  {
    const $l$39 = ($e$37) => {
      const $payload$38 = Html$targetValue($e$37);
      $hTyped$29($payload$38);
    };
    $w$7.addEventListener("input", ($e$40) => {
      Direct$send($l$39, $e$40);
    });
    const $l$45 = ($e$41) => {
      const $payload$42 = Direct$identity($e$41);
      $dispatch$44((($p$43) => MessageKeys$Clicked)($payload$42));
    };
    $w$12.addEventListener("click", ($e$46) => {
      Direct$send($l$45, $e$46);
    });
    const $l$48 = ($e$47) => {
      $dispatch$44({ $: "Nested", a: MessageKeys$A });
    };
    $w$13.addEventListener("click", ($e$49) => {
      Direct$send($l$48, $e$49);
    });
    const $l$51 = ($e$50) => {
      $dispatch$44({ $: "Nested", a: { $: "B", a: 7 } });
    };
    $w$14.addEventListener("click", ($e$52) => {
      Direct$send($l$51, $e$52);
    });
  }
  $g$21();
  $g$23();
  $g$26();
  $root$1.append($r$5);
  Direct$verify(() => {
    const $t$54 = $model$4.text;
    const $t$55 = $model$4.clicks > 1 ? "many" : "few";
    const $t$56 = String$fromInt($model$4.clicks);
    const $t$57 = String$fromInt($model$4.sub);
    if (!Direct$same($t$54, $s$17)) {
      Direct$wrong("the text hole at MessageKeys.beni:51:22", $s$17, $t$54);
    }
    if (!Direct$same($t$55, $s$18)) {
      Direct$wrong("the attribute `class` at MessageKeys.beni:52:24", $s$18, $t$55);
    }
    if (!Direct$same($t$56, $s$19)) {
      Direct$wrong("the text hole at MessageKeys.beni:53:13", $s$19, $t$56);
    }
    if (!Direct$same($t$57, $s$20)) {
      Direct$wrong("the text hole at MessageKeys.beni:58:21", $s$20, $t$57);
    }
  });
});
export { MessageKeys$main };
//# sourceMappingURL=MessageKeys.mjs.map
