import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$insertText, Direct$unset, Direct$listenRow, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
const Helpers$main = Tea$sandbox(($root$1, $t$2) => {
  const init$6 = { a: 0, b: 0, c: 0, name: "beni" };
  let $model$7 = init$6;
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
  const $make$39 = ($c$28, $b$29) => {
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
  };
  const $hany$42 = ($p$40) => {
    let $t$41;
    $c$0: {
      switch ($p$40.a) {
        case 1:
          {
            $t$41 = { ...$model$7, a: $model$7.a + 1 };
            break $c$0;
          }
        case 2:
          {
            $t$41 = { ...$model$7, b: $model$7.b + 1 };
            break $c$0;
          }
        default:
          {
            $t$41 = { ...$model$7, c: $model$7.c + 1 };
            break $c$0;
          }
      }
    }
    $model$7 = $t$41;
    $g$21($I$3);
    $g$24($I$3);
    $g$21($I$4);
    $g$24($I$4);
    $g$21($I$5);
    $g$24($I$5);
  };
  {
  }
  {
    const $t$43 = $model$7.name;
    $x$19.data = $t$43;
    $s$20 = $t$43;
  }
  const $args$46 = () => {
    const $t$44 = $model$7.a;
    const $t$45 = { $: "Go", a: 1 };
    return ["a", $t$44, $t$45];
  };
  const $l$51 = ($e$47, $r$48) => {
    const $t$49 = $model$7.a;
    const $t$50 = { $: "Go", a: 1 };
    const title$19 = "a";
    $hany$42({ $: "Go", a: 1 });
  };
  const $I$3 = $make$39($args$46, [$l$51]);
  $w$10.insertBefore($I$3.e, $w$16);
  const $args$54 = () => {
    const $t$52 = $model$7.b;
    const $t$53 = { $: "Go", a: 2 };
    return ["b", $t$52, $t$53];
  };
  const $l$59 = ($e$55, $r$56) => {
    const $t$57 = $model$7.b;
    const $t$58 = { $: "Go", a: 2 };
    const title$24 = "b";
    $hany$42({ $: "Go", a: 2 });
  };
  const $I$4 = $make$39($args$54, [$l$59]);
  $w$10.insertBefore($I$4.e, $w$17);
  const $args$62 = () => {
    const $t$60 = $model$7.c;
    const $t$61 = { $: "Go", a: 3 };
    return ["c", $t$60, $t$61];
  };
  const $l$67 = ($e$63, $r$64) => {
    const $t$65 = $model$7.c;
    const $t$66 = { $: "Go", a: 3 };
    const title$29 = "c";
    $hany$42({ $: "Go", a: 3 });
  };
  const $I$5 = $make$39($args$62, [$l$67]);
  $w$10.insertBefore($I$5.e, $w$18);
  $root$1.append($r$9);
  Direct$verify(() => {
    {
      const $t$68 = $model$7.name;
      if (!Direct$same($t$68, $s$20)) {
        Direct$wrong("the text hole at Helpers.beni:44:25", $s$20, $t$68);
      }
      if ($x$19.data !== `${$t$68}`) {
        Direct$wrong("the text hole at Helpers.beni:44:25 in the document", $x$19.data, `${$t$68}`);
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
    const $a$69 = $I$3.c();
    const title$42 = $a$69[0];
    const n$43 = $a$69[1];
    const msg$44 = $a$69[2];
    const $t$70 = n$43 + 1;
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
    if (!Direct$same($t$70, $I$3.s3)) {
      Direct$wrong("the text hole at Helpers.beni:52:12", $I$3.s3, $t$70);
    }
    if ($I$3.w6.data !== `${$t$70}`) {
      Direct$wrong("the text hole at Helpers.beni:52:12 in the document", $I$3.w6.data, `${$t$70}`);
    }
    const $a$71 = $I$4.c();
    const title$46 = $a$71[0];
    const n$47 = $a$71[1];
    const msg$48 = $a$71[2];
    const $t$72 = n$47 + 1;
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
    if (!Direct$same($t$72, $I$4.s3)) {
      Direct$wrong("the text hole at Helpers.beni:52:12", $I$4.s3, $t$72);
    }
    if ($I$4.w6.data !== `${$t$72}`) {
      Direct$wrong("the text hole at Helpers.beni:52:12 in the document", $I$4.w6.data, `${$t$72}`);
    }
    const $a$73 = $I$5.c();
    const title$50 = $a$73[0];
    const n$51 = $a$73[1];
    const msg$52 = $a$73[2];
    const $t$74 = n$51 + 1;
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
    if (!Direct$same($t$74, $I$5.s3)) {
      Direct$wrong("the text hole at Helpers.beni:52:12", $I$5.s3, $t$74);
    }
    if ($I$5.w6.data !== `${$t$74}`) {
      Direct$wrong("the text hole at Helpers.beni:52:12 in the document", $I$5.w6.data, `${$t$74}`);
    }
  });
});
export { Helpers$main };
//# sourceMappingURL=Helpers.mjs.map
