import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$on, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
const BakedQuoting$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { bt: "a`b", cr: "a\rb", dq: "a\"b", eq: "a=b", ff: "a\fb", gt: "a>b", lf: "a\nb", lt: "a<b", n: 0, slash: "a/", sp: "a b", sq: "a'b", tabbed: "a\tb" };
  let $model$4 = init$3;
  $t$2.innerHTML = "<main><button id=inc> </button><p id=ws data-ff=\"a\fb\"data-tab=\"a\tb\"data-lf=\"a\nb\"data-cr=\"a&#13;b\"data-sp=\"a b\"data-gt=\"a>b\"data-eq=\"a=b\"data-bt=\"a`b\"data-sq=\"a'b\"data-dq=\"a&quot;b\"data-lt=\"a&lt;b\"data-slash=\"a/\">ws";
  const $r$5 = $t$2.content;
  const $w$6 = $r$5.firstChild;
  const $w$7 = $w$6.firstChild;
  const $w$8 = $w$7.firstChild;
  const $w$9 = $w$7.nextSibling;
  let $s$10 = Direct$unset;
  const $g$11 = () => {
    const $t$12 = $model$4.n;
    if ($t$12 !== $s$10) {
      $w$8.data = $t$12;
      $s$10 = $t$12;
    }
  };
  const $hany$14 = ($p$13) => {
    $model$4 = { ...$model$4, n: $model$4.n + 1 };
    $g$11();
  };
  {
    const $l$16 = ($e$15) => {
      $hany$14("Inc");
    };
    Direct$on($w$7, "click", $l$16);
  }
  $g$11();
  $root$1.append($r$5);
  Direct$verify(() => {
    const $t$17 = $model$4.n;
    const $t$18 = $model$4.ff;
    const $t$19 = $model$4.tabbed;
    const $t$20 = $model$4.lf;
    const $t$21 = $model$4.cr;
    const $t$22 = $model$4.sp;
    const $t$23 = $model$4.gt;
    const $t$24 = $model$4.eq;
    const $t$25 = $model$4.bt;
    const $t$26 = $model$4.sq;
    const $t$27 = $model$4.dq;
    const $t$28 = $model$4.lt;
    const $t$29 = $model$4.slash;
    if (!Direct$same($t$17, $s$10)) {
      Direct$wrong("the text hole at BakedQuoting.beni:43:40", $s$10, $t$17);
    }
    if ($w$8.data !== `${$t$17}`) {
      Direct$wrong("the text hole at BakedQuoting.beni:43:40 in the document", $w$8.data, `${$t$17}`);
    }
    if ($w$9.getAttribute("data-ff") !== `${$t$18}`) {
      Direct$wrong("the attribute `data-ff` at BakedQuoting.beni:46:13 baked into the page", $w$9.getAttribute("data-ff"), `${$t$18}`);
    }
    if ($w$9.getAttribute("data-tab") !== `${$t$19}`) {
      Direct$wrong("the attribute `data-tab` at BakedQuoting.beni:47:13 baked into the page", $w$9.getAttribute("data-tab"), `${$t$19}`);
    }
    if ($w$9.getAttribute("data-lf") !== `${$t$20}`) {
      Direct$wrong("the attribute `data-lf` at BakedQuoting.beni:48:13 baked into the page", $w$9.getAttribute("data-lf"), `${$t$20}`);
    }
    if ($w$9.getAttribute("data-cr") !== `${$t$21}`) {
      Direct$wrong("the attribute `data-cr` at BakedQuoting.beni:49:13 baked into the page", $w$9.getAttribute("data-cr"), `${$t$21}`);
    }
    if ($w$9.getAttribute("data-sp") !== `${$t$22}`) {
      Direct$wrong("the attribute `data-sp` at BakedQuoting.beni:50:13 baked into the page", $w$9.getAttribute("data-sp"), `${$t$22}`);
    }
    if ($w$9.getAttribute("data-gt") !== `${$t$23}`) {
      Direct$wrong("the attribute `data-gt` at BakedQuoting.beni:51:13 baked into the page", $w$9.getAttribute("data-gt"), `${$t$23}`);
    }
    if ($w$9.getAttribute("data-eq") !== `${$t$24}`) {
      Direct$wrong("the attribute `data-eq` at BakedQuoting.beni:52:13 baked into the page", $w$9.getAttribute("data-eq"), `${$t$24}`);
    }
    if ($w$9.getAttribute("data-bt") !== `${$t$25}`) {
      Direct$wrong("the attribute `data-bt` at BakedQuoting.beni:53:13 baked into the page", $w$9.getAttribute("data-bt"), `${$t$25}`);
    }
    if ($w$9.getAttribute("data-sq") !== `${$t$26}`) {
      Direct$wrong("the attribute `data-sq` at BakedQuoting.beni:54:13 baked into the page", $w$9.getAttribute("data-sq"), `${$t$26}`);
    }
    if ($w$9.getAttribute("data-dq") !== `${$t$27}`) {
      Direct$wrong("the attribute `data-dq` at BakedQuoting.beni:55:13 baked into the page", $w$9.getAttribute("data-dq"), `${$t$27}`);
    }
    if ($w$9.getAttribute("data-lt") !== `${$t$28}`) {
      Direct$wrong("the attribute `data-lt` at BakedQuoting.beni:56:13 baked into the page", $w$9.getAttribute("data-lt"), `${$t$28}`);
    }
    if ($w$9.getAttribute("data-slash") !== `${$t$29}`) {
      Direct$wrong("the attribute `data-slash` at BakedQuoting.beni:57:13 baked into the page", $w$9.getAttribute("data-slash"), `${$t$29}`);
    }
  });
});
export { BakedQuoting$main };
//# sourceMappingURL=BakedQuoting.mjs.map
