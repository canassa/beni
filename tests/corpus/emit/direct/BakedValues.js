import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$send, Direct$wrong, Direct$same, Direct$safeUrl, Direct$verify } from "./_platform/Direct.mjs";
const BakedValues$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { below: 0 - 42, count: 7, empty: "", huge: 9007199254740993, link: "javascript:alert(1)", n: 0, ratio: 1.5, special: "a<b & \"c\" 'd' >", tab: 3 };
  let $model$4 = init$3;
  $t$2.innerHTML = "<main><button id=inc> </button><p id=count>7</p><p id=below>-42</p><p id=huge> </p><p id=ratio> </p><p id=special title=\"a&lt;b &amp; &quot;c&quot; 'd' >\">a&lt;b &amp; \"c\" 'd' ></p><p id=empty title> </p><span id=tab tabindex=3>tab</span><a id=link href>link";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild;
  const $w$8 = $w$7.firstChild;
  const $w$9 = $w$7.nextSibling;
  const $w$10 = $w$9.firstChild;
  const $w$11 = $w$9.nextSibling;
  const $w$12 = $w$11.firstChild;
  const $w$13 = $w$11.nextSibling;
  const $w$14 = $w$13.firstChild;
  const $w$15 = $w$13.nextSibling;
  const $w$16 = $w$15.firstChild;
  const $w$17 = $w$15.nextSibling;
  const $w$18 = $w$17.firstChild;
  const $w$19 = $w$17.nextSibling;
  const $w$20 = $w$19.firstChild;
  const $w$21 = $w$19.nextSibling;
  const $w$22 = $w$21.nextSibling;
  let $s$23 = Direct$unset;
  let $s$24 = Direct$unset;
  let $s$25 = Direct$unset;
  let $s$26 = Direct$unset;
  const $g$27 = () => {
    const $t$28 = $model$4.n;
    if ($t$28 !== $s$23) {
      $w$8.data = $t$28;
      $s$23 = $t$28;
    }
  };
  const $hany$30 = ($p$29) => {
    $model$4 = { ...$model$4, n: $model$4.n + 1 };
    $g$27();
  };
  {
    const $l$32 = ($e$31) => {
      $hany$30("Inc");
    };
    $w$7.addEventListener("click", ($e$33) => {
      Direct$send($l$32, $e$33);
    });
  }
  $g$27();
  {
    const $t$34 = $model$4.huge;
    $w$14.data = $t$34;
    $s$24 = $t$34;
  }
  {
    const $t$35 = $model$4.ratio;
    $w$16.data = $t$35;
    $s$25 = $t$35;
  }
  {
    const $t$36 = $model$4.empty;
    $w$20.data = $t$36;
    $s$26 = $t$36;
  }
  $root$1.append($r$5);
  Direct$verify(() => {
    const $t$37 = $model$4.n;
    const $t$38 = $model$4.count;
    const $t$39 = $model$4.below;
    const $t$40 = $model$4.huge;
    const $t$41 = $model$4.ratio;
    const $t$42 = $model$4.special;
    const $t$43 = $model$4.special;
    const $t$44 = $model$4.empty;
    const $t$45 = $model$4.empty;
    const $t$46 = $model$4.tab;
    const $t$47 = $model$4.link;
    if (!Direct$same($t$37, $s$23)) {
      Direct$wrong("the text hole at BakedValues.beni:41:40", $s$23, $t$37);
    }
    if ($w$8.data !== `${$t$37}`) {
      Direct$wrong("the text hole at BakedValues.beni:41:40 in the document", $w$8.data, `${$t$37}`);
    }
    if (!Direct$same($t$40, $s$24)) {
      Direct$wrong("the text hole at BakedValues.beni:44:22", $s$24, $t$40);
    }
    if ($w$14.data !== `${$t$40}`) {
      Direct$wrong("the text hole at BakedValues.beni:44:22 in the document", $w$14.data, `${$t$40}`);
    }
    if (!Direct$same($t$41, $s$25)) {
      Direct$wrong("the text hole at BakedValues.beni:45:23", $s$25, $t$41);
    }
    if ($w$16.data !== `${$t$41}`) {
      Direct$wrong("the text hole at BakedValues.beni:45:23 in the document", $w$16.data, `${$t$41}`);
    }
    if (!Direct$same($t$45, $s$26)) {
      Direct$wrong("the text hole at BakedValues.beni:47:43", $s$26, $t$45);
    }
    if ($w$20.data !== `${$t$45}`) {
      Direct$wrong("the text hole at BakedValues.beni:47:43 in the document", $w$20.data, `${$t$45}`);
    }
    if ($w$10.data !== `${$t$38}`) {
      Direct$wrong("the text BakedValues.beni:42:23 baked into the page", $w$10.data, `${$t$38}`);
    }
    if ($w$12.data !== `${$t$39}`) {
      Direct$wrong("the text BakedValues.beni:43:23 baked into the page", $w$12.data, `${$t$39}`);
    }
    if ($w$18.data !== `${$t$43}`) {
      Direct$wrong("the text BakedValues.beni:46:47 baked into the page", $w$18.data, `${$t$43}`);
    }
    if ($w$17.getAttribute("title") !== `${$t$42}`) {
      Direct$wrong("the attribute `title` at BakedValues.beni:46:25 baked into the page", $w$17.getAttribute("title"), `${$t$42}`);
    }
    if ($w$19.getAttribute("title") !== `${$t$44}`) {
      Direct$wrong("the attribute `title` at BakedValues.beni:47:23 baked into the page", $w$19.getAttribute("title"), `${$t$44}`);
    }
    if ($w$21.getAttribute("tabindex") !== `${$t$46}`) {
      Direct$wrong("the attribute `tabindex` at BakedValues.beni:48:24 baked into the page", $w$21.getAttribute("tabindex"), `${$t$46}`);
    }
    if ($w$22.getAttribute("href") !== Direct$safeUrl($t$47)) {
      Direct$wrong("the attribute `href` at BakedValues.beni:49:22 baked into the page", $w$22.getAttribute("href"), Direct$safeUrl($t$47));
    }
  });
});
export { BakedValues$main };
//# sourceMappingURL=BakedValues.mjs.map
