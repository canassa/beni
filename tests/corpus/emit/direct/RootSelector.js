import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$armTemplate, Direct$visitObserve, Direct$unset, Direct$listenRow, Direct$visitFactory, Direct$branch, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$arm, Direct$visitEnd, Direct$groupOnce, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
const RootSelector$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { n: 0, open: true };
  let $model$4 = init$3;
  $t$2.innerHTML = "<main><button>toggle</button><button>inc</button><p> ";
  const $T$5 = Direct$armTemplate($t$2, 0);
  $t$2.innerHTML = "<main><button>toggle</button><button>quiet</button><p>closed";
  const $T$6 = Direct$armTemplate($t$2, 0);
  $t$2.innerHTML = "";
  const $r$7 = $t$2.content;
  const $g$8 = ($r$9) => {
    Direct$visitObserve($r$9, 0);
    const $t$10 = $r$9.a;
    const $t$11 = $t$10[1];
    const $t$12 = $t$11.n;
    if ($t$12 !== $r$9.s2) {
      $r$9.w6.data = $t$12;
      $r$9.s2 = $t$12;
    }
  };
  const $l$18 = ($e$13, $r$14) => {
    const $t$15 = $r$14.a;
    const $t$16 = $t$15[1];
    $hToggle$17();
  };
  const $l$24 = ($e$19, $r$20) => {
    const $t$21 = $r$20.a;
    const $t$22 = $t$21[1];
    $hInc$23();
  };
  const $l$28 = ($e$25, $r$26) => {
    const $t$27 = $r$26.a;
    $hToggle$17();
  };
  const $l$33 = ($e$29, $r$30) => {
    const $t$31 = $r$30.a;
    $hQuiet$32();
  };
  const $A$34 = Direct$visitFactory(($u$36, $b$37, $a$38) => {
    const $e$39 = $T$5.cloneNode(true);
    const $w$40 = $e$39.firstChild;
    const $w$41 = $w$40.firstChild;
    const $w$42 = $w$41.nextSibling;
    const $w$43 = $w$42.nextSibling;
    const $w$44 = $w$43.firstChild;
    const $r$45 = { e: $e$39, a: $a$38, w6: $w$44, s2: Direct$unset };
    Direct$listenRow($w$41, "click", $l$18, $r$45);
    Direct$listenRow($w$42, "click", $l$24, $r$45);
    $g$8($r$45);
    return $r$45;
  });
  const $A$35 = Direct$visitFactory(($u$46, $b$47, $a$48) => {
    const $e$49 = $T$6.cloneNode(true);
    const $w$50 = $e$49.firstChild;
    const $w$51 = $w$50.firstChild;
    const $w$52 = $w$51.nextSibling;
    const $r$53 = { e: $e$49, a: $a$48 };
    Direct$listenRow($w$51, "click", $l$28, $r$53);
    Direct$listenRow($w$52, "click", $l$33, $r$53);
    return $r$53;
  });
  const $B$54 = Direct$branch($root$1, null, [$A$34, $A$35]);
  const $chooseRoot$59 = () => {
    const $t$58 = $model$4.open ? [0, $model$4] : [1];
    return $t$58;
  };
  const $hToggle$17 = () => {
    Direct$groupProgram(null);
    const $visitBefore$55 = Direct$visitBegin($root$1, 0);
    $model$4 = { ...$model$4, open: !$model$4.open };
    Direct$visitScope($root$1, []);
    {
      const $a$60 = $chooseRoot$59();
      const $n$61 = $a$60[0];
      if ($n$61 !== $B$54.k) {
        Direct$arm($B$54, $n$61, null, $a$60);
      } else {
        if ($B$54.i !== null) {
          $B$54.i.a = $a$60;
        }
      }
    }
    Direct$visitEnd($visitBefore$55);
  };
  const $hInc$23 = () => {
    Direct$groupProgram(null);
    const $visitBefore$62 = Direct$visitBegin($root$1, 1);
    $model$4 = { ...$model$4, n: $model$4.n + 1 };
    Direct$visitScope($root$1, []);
    {
      const $a$65 = $chooseRoot$59();
      const $n$66 = $a$65[0];
      if ($n$66 !== $B$54.k) {
        Direct$arm($B$54, $n$66, null, $a$65);
      } else {
        if ($B$54.i !== null) {
          $B$54.i.a = $a$65;
        }
        {
          if ($B$54.k === 0) {
            const $a$63 = $B$54.i;
            Direct$visitScope($a$63, [[0, true]]);
            if (Direct$groupOnce($a$63, 0)) {
              $g$8($a$63);
            }
          }
        }
      }
    }
    Direct$visitEnd($visitBefore$62);
  };
  const $hQuiet$32 = () => {
    Direct$groupProgram(null);
    const $visitBefore$67 = Direct$visitBegin($root$1, 2);
    $model$4 = $model$4;
    Direct$visitScope($root$1, []);
    {
      const $a$70 = $chooseRoot$59();
      const $n$71 = $a$70[0];
      if ($n$71 !== $B$54.k) {
        Direct$arm($B$54, $n$71, null, $a$70);
      } else {
        if ($B$54.i !== null) {
          $B$54.i.a = $a$70;
        }
      }
    }
    Direct$visitEnd($visitBefore$67);
  };
  {
  }
  {
    const $a$72 = $chooseRoot$59();
    const $n$73 = $a$72[0];
    Direct$arm($B$54, $n$73, null, $a$72);
  }
  $root$1.append($r$7);
  const $check$76 = ($r$74, $a$75) => {
  };
  const $check$82 = ($r$77, $a$78) => {
    const $t$79 = $a$78;
    const $t$80 = $t$79[1];
    const $t$81 = $t$80.n;
    if (!Direct$same($t$81, $r$77.s2)) {
      Direct$wrong("the text hole at RootSelector.beni:34:94", $r$77.s2, $t$81);
    }
    if ($r$77.w6.data !== `${$t$81}`) {
      Direct$wrong("the text hole at RootSelector.beni:34:94 in the document", $r$77.w6.data, `${$t$81}`);
    }
  };
  Direct$verify(() => {
  });
});
export { RootSelector$main };
//# sourceMappingURL=RootSelector.mjs.map
