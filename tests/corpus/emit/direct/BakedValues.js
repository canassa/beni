import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$send, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
const BakedValues$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { below: 0 - 42, count: 7, empty: "", huge: 9007199254740993, link: "javascript:alert(1)", n: 0, ratio: 1.5, special: "a<b & \"c\" 'd' >", tab: 3 };
  let $model$4 = init$3;
  $t$2.innerHTML = "<main><button id=inc> </button><p id=count>7</p><p id=below>-42</p><p id=huge> </p><p id=ratio> </p><p id=special title=\"a&lt;b &amp; &quot;c&quot; 'd' >\">a&lt;b &amp; \"c\" 'd' ></p><p id=empty title> </p><span id=tab tabindex=3>tab</span><a id=link href>link";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild;
  const $w$8 = $w$7.firstChild;
  const $w$9 = $w$7.nextSibling.nextSibling.nextSibling;
  const $w$10 = $w$9.firstChild;
  const $w$11 = $w$9.nextSibling;
  const $w$12 = $w$11.firstChild;
  const $w$13 = $w$11.nextSibling.nextSibling;
  const $w$14 = $w$13.firstChild;
  let $s$15 = Direct$unset;
  let $s$16 = Direct$unset;
  let $s$17 = Direct$unset;
  let $s$18 = Direct$unset;
  const $g$19 = () => {
    const $t$20 = $model$4.n;
    if ($t$20 !== $s$15) {
      $w$8.data = $t$20;
      $s$15 = $t$20;
    }
  };
  const $hany$22 = ($p$21) => {
    $model$4 = { ...$model$4, n: $model$4.n + 1 };
    $g$19();
  };
  {
    const $l$24 = ($e$23) => {
      $hany$22("Inc");
    };
    $w$7.addEventListener("click", ($e$25) => {
      Direct$send($l$24, $e$25);
    });
  }
  $g$19();
  {
    const $t$26 = $model$4.huge;
    $w$10.data = $t$26;
    $s$16 = $t$26;
  }
  {
    const $t$27 = $model$4.ratio;
    $w$12.data = $t$27;
    $s$17 = $t$27;
  }
  {
    const $t$28 = $model$4.empty;
    $w$14.data = $t$28;
    $s$18 = $t$28;
  }
  $root$1.append($r$5);
  Direct$verify(() => {
    const $t$29 = $model$4.n;
    const $t$30 = $model$4.count;
    const $t$31 = $model$4.below;
    const $t$32 = $model$4.huge;
    const $t$33 = $model$4.ratio;
    const $t$34 = $model$4.special;
    const $t$35 = $model$4.special;
    const $t$36 = $model$4.empty;
    const $t$37 = $model$4.empty;
    const $t$38 = $model$4.tab;
    const $t$39 = $model$4.link;
    if (!Direct$same($t$29, $s$15)) {
      Direct$wrong("the text hole at BakedValues.beni:41:40", $s$15, $t$29);
    }
    if (!Direct$same($t$32, $s$16)) {
      Direct$wrong("the text hole at BakedValues.beni:44:22", $s$16, $t$32);
    }
    if (!Direct$same($t$33, $s$17)) {
      Direct$wrong("the text hole at BakedValues.beni:45:23", $s$17, $t$33);
    }
    if (!Direct$same($t$37, $s$18)) {
      Direct$wrong("the text hole at BakedValues.beni:47:43", $s$18, $t$37);
    }
    if (`${$t$30}` !== "7") {
      Direct$wrong("the text BakedValues.beni:42:23 baked into the page", "7", `${$t$30}`);
    }
    if (`${$t$31}` !== "-42") {
      Direct$wrong("the text BakedValues.beni:43:23 baked into the page", "-42", `${$t$31}`);
    }
    if (`${$t$35}` !== "a<b & \"c\" 'd' >") {
      Direct$wrong("the text BakedValues.beni:46:47 baked into the page", "a<b & \"c\" 'd' >", `${$t$35}`);
    }
    if (`${$t$34}` !== "a<b & \"c\" 'd' >") {
      Direct$wrong("the attribute `title` at BakedValues.beni:46:25 baked into the page", "a<b & \"c\" 'd' >", `${$t$34}`);
    }
    if (`${$t$36}` !== "") {
      Direct$wrong("the attribute `title` at BakedValues.beni:47:23 baked into the page", "", `${$t$36}`);
    }
    if (`${$t$38}` !== "3") {
      Direct$wrong("the attribute `tabindex` at BakedValues.beni:48:24 baked into the page", "3", `${$t$38}`);
    }
    if (`${$t$39}` !== "javascript:alert(1)") {
      Direct$wrong("the attribute `href` at BakedValues.beni:49:22 baked into the page", "javascript:alert(1)", `${$t$39}`);
    }
  });
});
export { BakedValues$main };
//# sourceMappingURL=BakedValues.mjs.map
