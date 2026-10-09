import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$append, Direct$delegate, Direct$mount, Direct$adopt, Direct$wrong, Direct$safeUrl, Direct$same, Direct$verifyList, Direct$verify } from "./_platform/Direct.mjs";
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
  const $make$28 = ($it$19, $L$20, $j$21, $e$22) => {
    const $w$23 = $e$22.firstChild;
    const $w$24 = $w$23.firstChild;
    const $w$25 = $w$23.nextSibling;
    const $w$26 = $w$25.firstChild;
    const $r$27 = { e: $e$22, it: $it$19, l: $L$20, w2: $w$24, w3: $w$25, w4: $w$26 };
    $e$22.$r = $r$27;
    $w$25.$click = $l$18;
    return $r$27;
  };
  const $make$37 = ($it$29, $L$30, $j$31) => {
    const $e$32 = $T$7.cloneNode(true);
    const $w$33 = $e$32.firstChild;
    const $r$34 = { e: $e$32, it: $it$29, w1: $w$33, s0: Direct$unset };
    {
      const $it$35 = $r$34.it;
      const $t$36 = String$fromInt($it$35);
      $r$34.w1.data = $t$36;
      $r$34.s0 = $t$36;
    }
    return $r$34;
  };
  const $L$38 = { p: $w$12, n: null, r: [], m: $make$37, o: true, k: null, u: null };
  const $t$41 = ($p$40) => $p$40.id;
  const $key$42 = $t$41;
  const $L$39 = { p: $w$10, n: null, r: [], m: $make$28, o: false, k: $key$42, u: null };
  const $hany$17 = ($p$43) => {
    const id$13 = $p$43.a;
    $model$6 = { ...$model$6, opened: List$push($model$6.opened, id$13) };
    {
      const $t$44 = $model$6.opened;
      const $xs$45 = $t$44;
      Direct$append($L$38, $xs$45);
    }
  };
  {
  }
  Direct$delegate($L$39, $w$10, "click", "$click");
  {
    const $t$46 = $model$6.opened;
    const $xs$47 = $t$46;
    Direct$mount($L$38, $xs$47);
  }
  {
    const $t$48 = $model$6.menu;
    const $xs$49 = $t$48;
    Direct$adopt($L$39, $w$11, $xs$49);
  }
  $root$1.append($r$8);
  const $check$56 = ($r$50) => {
    const $it$51 = $r$50.it;
    const $t$52 = $it$51.id;
    const $t$53 = $it$51.href;
    const $t$54 = $it$51.label;
    const $t$55 = $it$51.label;
    if ($r$50.w2.data !== `${$t$52}`) {
      Direct$wrong("the text BakedList.beni:41:28 baked into the page", $r$50.w2.data, `${$t$52}`);
    }
    if ($r$50.w4.data !== `${$t$55}`) {
      Direct$wrong("the text BakedList.beni:43:29 baked into the page", $r$50.w4.data, `${$t$55}`);
    }
    if ($r$50.w3.getAttribute("href") !== Direct$safeUrl($t$53)) {
      Direct$wrong("the attribute `href` at BakedList.beni:42:28 baked into the page", $r$50.w3.getAttribute("href"), Direct$safeUrl($t$53));
    }
    if ($r$50.w3.getAttribute("title") !== `${$t$54}`) {
      Direct$wrong("the attribute `title` at BakedList.beni:42:45 baked into the page", $r$50.w3.getAttribute("title"), `${$t$54}`);
    }
  };
  const $check$60 = ($r$57) => {
    const $it$58 = $r$57.it;
    const $t$59 = String$fromInt($it$58);
    if (!Direct$same($t$59, $r$57.s0)) {
      Direct$wrong("the text hole at BakedList.beni:50:63", $r$57.s0, $t$59);
    }
    if ($r$57.w1.data !== `${$t$59}`) {
      Direct$wrong("the text hole at BakedList.beni:50:63 in the document", $r$57.w1.data, `${$t$59}`);
    }
  };
  Direct$verify(() => {
    {
      const $t$61 = $model$6.opened;
      const $xs$62 = $t$61;
      Direct$verifyList($L$38, $xs$62, $check$60, "the `For` at BakedList.beni:50:14", false);
    }
    {
      const $t$63 = $model$6.menu;
      const $xs$64 = $t$63;
      Direct$verifyList($L$39, $xs$64, $check$56, "the `For` at BakedList.beni:38:14", false);
    }
  });
});
export { BakedList$main };
//# sourceMappingURL=BakedList.mjs.map
