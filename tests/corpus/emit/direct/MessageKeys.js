import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$visitObserve, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$visitEnd, Direct$on, Direct$identity, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
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
    Direct$visitObserve($root$1, 0);
    const $t$22 = $model$4.text;
    if ($t$22 !== $s$17) {
      $w$9.data = $t$22;
      $s$17 = $t$22;
    }
  };
  const $g$23 = () => {
    Direct$visitObserve($root$1, 1);
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
    Direct$visitObserve($root$1, 2);
    const $t$27 = String$fromInt($model$4.sub);
    if ($t$27 !== $s$20) {
      $w$16.data = $t$27;
      $s$20 = $t$27;
    }
  };
  const $hTyped$30 = ($p$28) => {
    Direct$groupProgram(null);
    const $visitBefore$29 = Direct$visitBegin($root$1, 0);
    $model$4 = { ...$model$4, text: $p$28 };
    Direct$visitScope($root$1, [[0, true], [1, false], [2, false]]);
    $g$21();
    Direct$visitEnd($visitBefore$29);
  };
  const $hClicked$32 = () => {
    Direct$groupProgram(null);
    const $visitBefore$31 = Direct$visitBegin($root$1, 1);
    $model$4 = { ...$model$4, clicks: $model$4.clicks + 1 };
    Direct$visitScope($root$1, [[0, false], [1, true], [2, false]]);
    $g$23();
    Direct$visitEnd($visitBefore$31);
  };
  const $hNested$A$36 = ($p$33) => {
    Direct$groupProgram(null);
    const $visitBefore$34 = Direct$visitBegin($root$1, 2);
    const sub$17 = $p$33.a;
    let $t$35;
    if (sub$17.$ === "A") {
      $t$35 = { ...$model$4, sub: $model$4.sub + 1 };
    } else {
      const n$18 = sub$17.a;
      $t$35 = { ...$model$4, sub: n$18 };
    }
    $model$4 = $t$35;
    Direct$visitScope($root$1, [[0, false], [1, false], [2, true]]);
    $g$26();
    Direct$visitEnd($visitBefore$34);
  };
  const $hNested$B$40 = ($p$37) => {
    Direct$groupProgram(null);
    const $visitBefore$38 = Direct$visitBegin($root$1, 3);
    const sub$22 = $p$37.a;
    let $t$39;
    if (sub$22.$ === "A") {
      $t$39 = { ...$model$4, sub: $model$4.sub + 1 };
    } else {
      const n$23 = sub$22.a;
      $t$39 = { ...$model$4, sub: n$23 };
    }
    $model$4 = $t$39;
    Direct$visitScope($root$1, [[0, false], [1, false], [2, true]]);
    $g$26();
    Direct$visitEnd($visitBefore$38);
  };
  const $dispatch$47 = ($msg$53) => {
    if ($msg$53.$ === "Typed") {
      $hTyped$30($msg$53.a);
      return;
    }
    if ($msg$53.$ === "Clicked") {
      $hClicked$32();
      return;
    }
    if ($msg$53.$ === "Nested" && $msg$53.a.$ === "A") {
      $hNested$A$36($msg$53);
      return;
    }
    $hNested$B$40($msg$53);
  };
  {
    const $l$43 = ($e$41) => {
      const $payload$42 = Html$targetValue($e$41);
      $hTyped$30($payload$42);
    };
    Direct$on($w$7, "input", $l$43);
    const $l$48 = ($e$44) => {
      const $payload$45 = Direct$identity($e$44);
      $dispatch$47((($p$46) => MessageKeys$Clicked)($payload$45));
    };
    Direct$on($w$12, "click", $l$48);
    const $l$50 = ($e$49) => {
      $dispatch$47({ $: "Nested", a: MessageKeys$A });
    };
    Direct$on($w$13, "click", $l$50);
    const $l$52 = ($e$51) => {
      $dispatch$47({ $: "Nested", a: { $: "B", a: 7 } });
    };
    Direct$on($w$14, "click", $l$52);
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
    if ($w$9.data !== `${$t$54}`) {
      Direct$wrong("the text hole at MessageKeys.beni:51:22 in the document", $w$9.data, `${$t$54}`);
    }
    if (!Direct$same($t$55, $s$18)) {
      Direct$wrong("the attribute `class` at MessageKeys.beni:52:24", $s$18, $t$55);
    }
    if ($w$10.getAttribute("class") !== `${$t$55}`) {
      Direct$wrong("the attribute `class` at MessageKeys.beni:52:24 in the document", $w$10.getAttribute("class"), `${$t$55}`);
    }
    if (!Direct$same($t$56, $s$19)) {
      Direct$wrong("the text hole at MessageKeys.beni:53:13", $s$19, $t$56);
    }
    if ($w$11.data !== `${$t$56}`) {
      Direct$wrong("the text hole at MessageKeys.beni:53:13 in the document", $w$11.data, `${$t$56}`);
    }
    if (!Direct$same($t$57, $s$20)) {
      Direct$wrong("the text hole at MessageKeys.beni:58:21", $s$20, $t$57);
    }
    if ($w$16.data !== `${$t$57}`) {
      Direct$wrong("the text hole at MessageKeys.beni:58:21 in the document", $w$16.data, `${$t$57}`);
    }
  });
});
export { MessageKeys$main };
//# sourceMappingURL=MessageKeys.mjs.map
