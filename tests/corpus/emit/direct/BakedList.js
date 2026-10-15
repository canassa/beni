import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$visitFactory, Direct$unset, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$append, Direct$visitEnd, Direct$delegate, Direct$adopt, Direct$wrong, Direct$safeUrl, Direct$same, Direct$verifyList, Direct$verify } from "./_platform/Direct.mjs";
import { String$fromInt } from "./_core/String.mjs";
import { List$push } from "./_core/List.mjs";
const BakedList$main = Tea$sandbox(($root$1, $t$2) => {
  const init$5 = { menu: [{ href: "#home", id: 1, label: "Home" }, { href: "#faq", id: 22, label: "Q&A <faq>" }, { href: "javascript:alert(1)", id: 0 - 3, label: "\"Quoted\"" }], opened: [] };
  let $model$6 = init$5;
  $t$2.innerHTML = "<li> </li>";
  const $T$7 = $t$2.content.firstChild;
  $t$2.innerHTML = "<main><ul id=menu><li><b>1</b><a href=#home title=Home>Home</a></li><li><b>22</b><a href=#faq title=\"Q&amp;A &lt;faq>\">Q&amp;A &lt;faq></a></li><li><b>-3</b><a href title=\"&quot;Quoted&quot;\">\"Quoted\"</a></li></ul><ol id=opened></ol></main>";
  const $r$8 = $t$2.content;
  const $w$9 = $r$8.firstChild;
  const $w$10 = $w$9.firstChild;
  const $w$11 = $w$10.firstChild;
  const $w$12 = $w$10.nextSibling;
  const $l$18 = ($e$13, $r$14) => {
    const $it$15 = $r$14.it;
    const $t$16 = $it$15.id;
    $hany$17({ $: "Open", a: $t$16 });
  };
  const $make$28 = Direct$visitFactory(($it$19, $L$20, $j$21, $e$22) => {
    const $w$23 = $e$22.firstChild;
    const $w$24 = $w$23.firstChild;
    const $w$25 = $w$23.nextSibling;
    const $w$26 = $w$25.firstChild;
    const $r$27 = { e: $e$22, it: $it$19, l: 1, w2: $w$24, w3: $w$25, w4: $w$26 };
    $e$22.$r = $r$27;
    $e$22.$v = $L$20;
    $w$25.$click = $l$18;
    return $r$27;
  });
  const $make$37 = Direct$visitFactory(($it$29, $L$30, $j$31) => {
    const $e$32 = $T$7.cloneNode(true);
    const $w$33 = $e$32.firstChild;
    const $r$34 = { e: $e$32, it: $it$29, w1: $w$33, s0: Direct$unset };
    $e$32.$v = $L$30;
    {
      const $it$35 = $r$34.it;
      const $t$36 = String$fromInt($it$35);
      $r$34.w1.data = $t$36;
      $r$34.s0 = $t$36;
    }
    return $r$34;
  });
  const $L$38 = { p: $w$12, n: null, r: [], m: $make$37, o: true, k: null, u: null, w: null, x: null, d: null, z: Direct$unset, i: false };
  const $t$41 = ($p$40) => $p$40.id;
  const $key$42 = $t$41;
  const $L$39 = { p: $w$10, n: null, r: [], m: $make$28, o: false, k: $key$42, u: null, w: null, x: null, d: null, z: Direct$unset, i: false };
  const $hany$17 = ($p$43) => {
    Direct$groupProgram(null);
    const $visitBefore$44 = Direct$visitBegin($root$1, 0);
    const id$13 = $p$43.a;
    $model$6 = { ...$model$6, opened: List$push($model$6.opened, id$13) };
    Direct$visitScope($root$1, []);
    {
      const $t$45 = $model$6.opened;
      const $xs$46 = $t$45;
      Direct$append($L$38, $xs$46);
    }
    Direct$visitEnd($visitBefore$44);
  };
  {
  }
  Direct$delegate(1, $w$10, "click", "$click");
  {
    const $t$47 = $model$6.opened;
    const $xs$48 = $t$47;
    Direct$append($L$38, $xs$48);
  }
  {
    const $t$49 = $model$6.menu;
    const $xs$50 = $t$49;
    Direct$adopt($L$39, $w$11, $xs$50);
  }
  $root$1.append($r$8);
  const $check$58 = ($r$51) => {
    const $it$53 = $r$51.it;
    const $t$54 = $it$53.id;
    const $t$55 = $it$53.href;
    const $t$56 = $it$53.label;
    const $t$57 = $it$53.label;
    if ($r$51.w2.data !== `${$t$54}`) {
      Direct$wrong("the text BakedList.beni:41:28 baked into the page", $r$51.w2.data, `${$t$54}`);
    }
    if ($r$51.w4.data !== `${$t$57}`) {
      Direct$wrong("the text BakedList.beni:43:29 baked into the page", $r$51.w4.data, `${$t$57}`);
    }
    if ($r$51.w3.getAttribute("href") !== Direct$safeUrl($t$55)) {
      Direct$wrong("the attribute `href` at BakedList.beni:42:28 baked into the page", $r$51.w3.getAttribute("href"), Direct$safeUrl($t$55));
    }
    if ($r$51.w3.getAttribute("title") !== `${$t$56}`) {
      Direct$wrong("the attribute `title` at BakedList.beni:42:45 baked into the page", $r$51.w3.getAttribute("title"), `${$t$56}`);
    }
  };
  const $check$63 = ($r$59) => {
    const $it$61 = $r$59.it;
    const $t$62 = String$fromInt($it$61);
    if (!Direct$same($t$62, $r$59.s0)) {
      Direct$wrong("the text hole at BakedList.beni:50:63", $r$59.s0, $t$62);
    }
    if ($r$59.w1.data !== `${$t$62}`) {
      Direct$wrong("the text hole at BakedList.beni:50:63 in the document", $r$59.w1.data, `${$t$62}`);
    }
  };
  Direct$verify(() => {
    {
      const $t$64 = $model$6.opened;
      const $xs$65 = $t$64;
      Direct$verifyList($L$38, $xs$65, $check$63, "the `For` at BakedList.beni:50:14", false);
    }
    {
      const $t$66 = $model$6.menu;
      const $xs$67 = $t$66;
      Direct$verifyList($L$39, $xs$67, $check$58, "the `For` at BakedList.beni:38:14", false);
    }
  });
});
export { BakedList$main };
//# sourceMappingURL=BakedList.mjs.map
