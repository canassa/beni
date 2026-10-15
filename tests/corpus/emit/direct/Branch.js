import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$armTemplate, Direct$visitObserve, Direct$unset, Direct$visitFactory, Direct$branch, Direct$groupProgram, Direct$visitBegin, Direct$visitScope, Direct$groupOnce, Direct$templateValue, Direct$arm, Direct$visitEnd, Direct$on, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { Basics$append } from "./_core/Basics.mjs";
const Branch$Closed = { $: "Closed", a: null };
const Branch$main = Tea$sandbox(($root$1, $t$2) => {
  const $init$3 = { $: "Open", a: "ada" };
  let $model$4 = $init$3;
  $t$2.innerHTML = "<p> ";
  const $T$5 = Direct$armTemplate($t$2, 0);
  $t$2.innerHTML = "<p>closed";
  const $T$6 = Direct$armTemplate($t$2, 0);
  $t$2.innerHTML = "<main><button>rename</button><button>close";
  const $r$7 = $t$2.content;
  const $w$8 = $r$7.firstChild;
  const $w$9 = $w$8.firstChild;
  const $w$10 = $w$9.nextSibling;
  const $g$11 = ($r$12) => {
    Direct$visitObserve($r$12, 0);
    const $t$13 = $r$12.a;
    const $t$14 = $t$13[1];
    if ($t$14 !== $r$12.s0) {
      $r$12.w1.data = $t$14;
      $r$12.s0 = $t$14;
    }
  };
  const $A$15 = Direct$visitFactory(($u$17, $b$18, $a$19) => {
    const $e$20 = $T$5.cloneNode(true);
    const $w$21 = $e$20.firstChild;
    const $w$22 = $w$21.firstChild;
    const $r$23 = { e: $e$20, a: $a$19, w1: $w$22, s0: Direct$unset };
    $g$11($r$23);
    return $r$23;
  });
  const $A$16 = Direct$visitFactory(($u$24, $b$25, $a$26) => {
    const $e$27 = $T$6.cloneNode(true);
    const $w$28 = $e$27.firstChild;
    const $r$29 = { e: $e$27, a: $a$26 };
    return $r$29;
  });
  const $B$30 = Direct$branch($w$8, null, [$A$15, $A$16]);
  const $patchAll$31 = () => {
  };
  const $hRename$40 = () => {
    Direct$groupProgram(null);
    const $visitBefore$32 = Direct$visitBegin($root$1, 0);
    let $t$33;
    if ($model$4.$ === "Open") {
      const name$5 = $model$4.a;
      $t$33 = { $: "Open", a: Basics$append(name$5, "!") };
    } else {
      $t$33 = $model$4;
    }
    $model$4 = $t$33;
    Direct$visitScope($root$1, []);
    {
      const $a$37 = Direct$templateValue("/0:96", () => {
        let $t$39;
        {
          let $t$38;
          if ($model$4.$ === "Open") {
            const name$7 = $model$4.a;
            $t$38 = [0, name$7];
          } else {
            $t$38 = [1];
          }
          $t$39 = $t$38;
        }
        return $t$39;
      });
      const $n$36 = $a$37[0];
      if ($n$36 !== $B$30.k) {
        Direct$arm($B$30, $n$36, null, $a$37);
      } else {
        if ($B$30.i !== null) {
          $B$30.i.a = $a$37;
        }
        {
          if ($B$30.k === 0) {
            const $a$34 = $B$30.i;
            Direct$visitScope($a$34, [[0, true]]);
            if (Direct$groupOnce($a$34, 0)) {
              $g$11($a$34);
            }
          }
        }
      }
    }
    Direct$visitEnd($visitBefore$32);
  };
  const $hClose$48 = () => {
    Direct$groupProgram(null);
    const $visitBefore$41 = Direct$visitBegin($root$1, 1);
    $model$4 = Branch$Closed;
    Direct$visitScope($root$1, []);
    {
      const $a$45 = Direct$templateValue("/0:96", () => {
        let $t$47;
        {
          let $t$46;
          if ($model$4.$ === "Open") {
            const name$12 = $model$4.a;
            $t$46 = [0, name$12];
          } else {
            $t$46 = [1];
          }
          $t$47 = $t$46;
        }
        return $t$47;
      });
      const $n$44 = $a$45[0];
      if ($n$44 !== $B$30.k) {
        Direct$arm($B$30, $n$44, null, $a$45);
      } else {
        if ($B$30.i !== null) {
          $B$30.i.a = $a$45;
        }
        {
          if ($B$30.k === 0) {
            const $a$42 = $B$30.i;
            Direct$visitScope($a$42, [[0, true]]);
            if (Direct$groupOnce($a$42, 0)) {
              $g$11($a$42);
            }
          }
        }
      }
    }
    $patchAll$31();
    Direct$visitEnd($visitBefore$41);
  };
  {
    Direct$on($w$9, "click", $hRename$40);
    Direct$on($w$10, "click", $hClose$48);
  }
  {
    const $a$52 = Direct$templateValue("/0:96", () => {
      let $t$54;
      {
        let $t$53;
        if ($model$4.$ === "Open") {
          const name$18 = $model$4.a;
          $t$53 = [0, name$18];
        } else {
          $t$53 = [1];
        }
        $t$54 = $t$53;
      }
      return $t$54;
    });
    const $n$51 = $a$52[0];
    Direct$arm($B$30, $n$51, null, $a$52);
  }
  $root$1.append($r$7);
  const $check$57 = ($r$55, $a$56) => {
  };
  const $check$62 = ($r$58, $a$59) => {
    const $t$60 = $a$59;
    const $t$61 = $t$60[1];
    if (!Direct$same($t$61, $r$58.s0)) {
      Direct$wrong("the text hole at Branch.beni:47:20", $r$58.s0, $t$61);
    }
    if ($r$58.w1.data !== `${$t$61}`) {
      Direct$wrong("the text hole at Branch.beni:47:20 in the document", $r$58.w1.data, `${$t$61}`);
    }
  };
  Direct$verify(() => {
    {
      const $a$64 = Direct$templateValue("/0:96", () => {
        let $t$66;
        {
          let $t$65;
          if ($model$4.$ === "Open") {
            const name$24 = $model$4.a;
            $t$65 = [0, name$24];
          } else {
            $t$65 = [1];
          }
          $t$66 = $t$65;
        }
        return $t$66;
      });
      const $n$63 = $a$64[0];
      if ($n$63 !== $B$30.k) {
        Direct$wrong("the arm of the branch at Branch.beni:45:9", $B$30.k, $n$63);
      } else {
        if ($B$30.k === 0) {
          $check$62($B$30.i, $a$64);
        }
        if ($B$30.k === 1) {
          $check$57($B$30.i, $a$64);
        }
      }
    }
  });
});
export { Branch$main };
//# sourceMappingURL=Branch.mjs.map
