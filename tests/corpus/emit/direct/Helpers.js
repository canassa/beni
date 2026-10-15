import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$insertText, Direct$unset, Direct$visitObserve, Direct$listenRow, Direct$visitFactory, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$visitEnd, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
const Helpers$main = Tea$sandbox(($root$1, $t$2) => {
  const $init$6 = { a: 0, b: 0, c: 0, name: "beni" };
  let $model$7 = $init$6;
  $t$2.innerHTML = "<div class=cell><span> </span><b> </b><i> ";
  const $T$8 = $t$2.content.firstChild;
  $t$2.innerHTML = "<main><h1>Hello, </h1><button id=run type=button>Create 1,000 rows</button><button id=add type=button>Append 1,000 rows</button><!><!><!>";
  const $r$9 = $t$2.content;
  const $w$10 = $r$9.firstChild;
  const $w$11 = $w$10.firstChild;
  const $w$12 = $w$11.nextSibling;
  const $w$13 = $w$12.firstChild;
  const $w$14 = $w$12.nextSibling;
  const $w$15 = $w$14.firstChild;
  const $w$16 = $w$14.nextSibling;
  const $w$17 = $w$16.nextSibling;
  const $w$18 = $w$17.nextSibling;
  const $x$19 = Direct$insertText($w$11, null, "");
  let $s$20 = Direct$unset;
  const $g$21 = ($r$22) => {
    Direct$visitObserve($r$22, 5);
    const $a$23 = $r$22.c();
    const title$2 = $a$23[0];
    const n$3 = $a$23[1];
    const msg$4 = $a$23[2];
    if (n$3 !== $r$22.s2) {
      $r$22.w4.data = n$3;
      $r$22.s2 = n$3;
    }
  };
  const $g$24 = ($r$25) => {
    Direct$visitObserve($r$25, 6);
    const $a$26 = $r$25.c();
    const title$6 = $a$26[0];
    const n$7 = $a$26[1];
    const msg$8 = $a$26[2];
    const $t$27 = n$7 + 1;
    if ($t$27 !== $r$25.s3) {
      $r$25.w6.data = $t$27;
      $r$25.s3 = $t$27;
    }
  };
  const $make$39 = Direct$visitFactory(($c$28, $b$29) => {
    const $e$30 = $T$8.cloneNode(true);
    const $w$31 = $e$30.firstChild;
    const $w$32 = $w$31.firstChild;
    const $w$33 = $w$31.nextSibling;
    const $w$34 = $w$33.firstChild;
    const $w$35 = $w$33.nextSibling;
    const $w$36 = $w$35.firstChild;
    const $r$37 = { e: $e$30, c: $c$28, w2: $w$32, w4: $w$34, w6: $w$36, s1: Direct$unset, s2: Direct$unset, s3: Direct$unset };
    Direct$listenRow($e$30, "click", $b$29[0], $r$37);
    {
      const $a$38 = $r$37.c();
      const title$10 = $a$38[0];
      const n$11 = $a$38[1];
      const msg$12 = $a$38[2];
      $r$37.w2.data = title$10;
      $r$37.s1 = title$10;
    }
    $g$21($r$37);
    $g$24($r$37);
    return $r$37;
  });
  const $hany$43 = ($p$40) => {
    Direct$groupProgram(null);
    const $visitBefore$41 = Direct$visitBegin($root$1, 0);
    let $t$42;
    $c$0: {
      switch ($p$40.a) {
        case 1:
          {
            $t$42 = { ...$model$7, a: $model$7.a + 1 };
            break $c$0;
          }
        case 2:
          {
            $t$42 = { ...$model$7, b: $model$7.b + 1 };
            break $c$0;
          }
        default:
          {
            $t$42 = { ...$model$7, c: $model$7.c + 1 };
            break $c$0;
          }
      }
    }
    $model$7 = $t$42;
    Direct$visitScope($root$1, [[0, false], [1, false], [2, false], [3, false]]);
    Direct$visitScope($I$3, [[4, false], [5, true], [6, true]]);
    $g$21($I$3);
    $g$24($I$3);
    Direct$visitScope($I$4, [[4, false], [5, true], [6, true]]);
    $g$21($I$4);
    $g$24($I$4);
    Direct$visitScope($I$5, [[4, false], [5, true], [6, true]]);
    $g$21($I$5);
    $g$24($I$5);
    Direct$visitEnd($visitBefore$41);
  };
  {
  }
  {
    const $t$44 = $model$7.name;
    $x$19.data = $t$44;
    $s$20 = $t$44;
  }
  const $args$47 = () => {
    const $t$45 = $model$7.a;
    const $t$46 = { $: "Go", a: 1 };
    return ["a", $t$45, $t$46];
  };
  const $l$52 = ($e$48, $r$49) => {
    const $t$50 = $model$7.a;
    const $t$51 = { $: "Go", a: 1 };
    const title$19 = "a";
    $hany$43({ $: "Go", a: 1 });
  };
  const $I$3 = $make$39($args$47, [$l$52]);
  $w$10.insertBefore($I$3.e, $w$16);
  const $args$55 = () => {
    const $t$53 = $model$7.b;
    const $t$54 = { $: "Go", a: 2 };
    return ["b", $t$53, $t$54];
  };
  const $l$60 = ($e$56, $r$57) => {
    const $t$58 = $model$7.b;
    const $t$59 = { $: "Go", a: 2 };
    const title$24 = "b";
    $hany$43({ $: "Go", a: 2 });
  };
  const $I$4 = $make$39($args$55, [$l$60]);
  $w$10.insertBefore($I$4.e, $w$17);
  const $args$63 = () => {
    const $t$61 = $model$7.c;
    const $t$62 = { $: "Go", a: 3 };
    return ["c", $t$61, $t$62];
  };
  const $l$68 = ($e$64, $r$65) => {
    const $t$66 = $model$7.c;
    const $t$67 = { $: "Go", a: 3 };
    const title$29 = "c";
    $hany$43({ $: "Go", a: 3 });
  };
  const $I$5 = $make$39($args$63, [$l$68]);
  $w$10.insertBefore($I$5.e, $w$18);
  $root$1.append($r$9);
  Direct$verify(() => {
    {
      const $t$69 = $model$7.name;
      if (!Direct$same($t$69, $s$20)) {
        Direct$wrong("the text hole at Helpers.beni:44:25", $s$20, $t$69);
      }
      if ($x$19.data !== `${$t$69}`) {
        Direct$wrong("the text hole at Helpers.beni:44:25 in the document", $x$19.data, `${$t$69}`);
      }
    }
    {
      const id$36 = "run";
      const text$37 = "Create 1,000 rows";
      if ($w$13.data !== `${text$37}`) {
        Direct$wrong("the text Helpers.beni:40:48 baked into the page", $w$13.data, `${text$37}`);
      }
      if ($w$12.getAttribute("id") !== `${id$36}`) {
        Direct$wrong("the attribute `id` at Helpers.beni:40:26 baked into the page", $w$12.getAttribute("id"), `${id$36}`);
      }
    }
    {
      const id$39 = "add";
      const text$40 = "Append 1,000 rows";
      if ($w$15.data !== `${text$40}`) {
        Direct$wrong("the text Helpers.beni:40:48 baked into the page", $w$15.data, `${text$40}`);
      }
      if ($w$14.getAttribute("id") !== `${id$39}`) {
        Direct$wrong("the attribute `id` at Helpers.beni:40:26 baked into the page", $w$14.getAttribute("id"), `${id$39}`);
      }
    }
    const $a$70 = $I$3.c();
    const title$42 = $a$70[0];
    const n$43 = $a$70[1];
    const msg$44 = $a$70[2];
    const $t$71 = n$43 + 1;
    if (!Direct$same(title$42, $I$3.s1)) {
      Direct$wrong("the text hole at Helpers.beni:50:15", $I$3.s1, title$42);
    }
    if ($I$3.w2.data !== `${title$42}`) {
      Direct$wrong("the text hole at Helpers.beni:50:15 in the document", $I$3.w2.data, `${title$42}`);
    }
    if (!Direct$same(n$43, $I$3.s2)) {
      Direct$wrong("the text hole at Helpers.beni:51:12", $I$3.s2, n$43);
    }
    if ($I$3.w4.data !== `${n$43}`) {
      Direct$wrong("the text hole at Helpers.beni:51:12 in the document", $I$3.w4.data, `${n$43}`);
    }
    if (!Direct$same($t$71, $I$3.s3)) {
      Direct$wrong("the text hole at Helpers.beni:52:12", $I$3.s3, $t$71);
    }
    if ($I$3.w6.data !== `${$t$71}`) {
      Direct$wrong("the text hole at Helpers.beni:52:12 in the document", $I$3.w6.data, `${$t$71}`);
    }
    const $a$72 = $I$4.c();
    const title$46 = $a$72[0];
    const n$47 = $a$72[1];
    const msg$48 = $a$72[2];
    const $t$73 = n$47 + 1;
    if (!Direct$same(title$46, $I$4.s1)) {
      Direct$wrong("the text hole at Helpers.beni:50:15", $I$4.s1, title$46);
    }
    if ($I$4.w2.data !== `${title$46}`) {
      Direct$wrong("the text hole at Helpers.beni:50:15 in the document", $I$4.w2.data, `${title$46}`);
    }
    if (!Direct$same(n$47, $I$4.s2)) {
      Direct$wrong("the text hole at Helpers.beni:51:12", $I$4.s2, n$47);
    }
    if ($I$4.w4.data !== `${n$47}`) {
      Direct$wrong("the text hole at Helpers.beni:51:12 in the document", $I$4.w4.data, `${n$47}`);
    }
    if (!Direct$same($t$73, $I$4.s3)) {
      Direct$wrong("the text hole at Helpers.beni:52:12", $I$4.s3, $t$73);
    }
    if ($I$4.w6.data !== `${$t$73}`) {
      Direct$wrong("the text hole at Helpers.beni:52:12 in the document", $I$4.w6.data, `${$t$73}`);
    }
    const $a$74 = $I$5.c();
    const title$50 = $a$74[0];
    const n$51 = $a$74[1];
    const msg$52 = $a$74[2];
    const $t$75 = n$51 + 1;
    if (!Direct$same(title$50, $I$5.s1)) {
      Direct$wrong("the text hole at Helpers.beni:50:15", $I$5.s1, title$50);
    }
    if ($I$5.w2.data !== `${title$50}`) {
      Direct$wrong("the text hole at Helpers.beni:50:15 in the document", $I$5.w2.data, `${title$50}`);
    }
    if (!Direct$same(n$51, $I$5.s2)) {
      Direct$wrong("the text hole at Helpers.beni:51:12", $I$5.s2, n$51);
    }
    if ($I$5.w4.data !== `${n$51}`) {
      Direct$wrong("the text hole at Helpers.beni:51:12 in the document", $I$5.w4.data, `${n$51}`);
    }
    if (!Direct$same($t$75, $I$5.s3)) {
      Direct$wrong("the text hole at Helpers.beni:52:12", $I$5.s3, $t$75);
    }
    if ($I$5.w6.data !== `${$t$75}`) {
      Direct$wrong("the text hole at Helpers.beni:52:12 in the document", $I$5.w6.data, `${$t$75}`);
    }
  });
});
export { Helpers$main };
//# sourceMappingURL=Helpers.mjs.map
