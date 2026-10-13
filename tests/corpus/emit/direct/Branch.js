import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$armTemplate, Direct$unset, Direct$branch, Direct$arm, Direct$on, Direct$wrong, Direct$same, Direct$verify } from "./_platform/Direct.mjs";
import { Basics$append } from "./_core/Basics.mjs";
const Branch$Closed = { $: "Closed", a: null };
const Branch$main = Tea$sandbox(($root$1, $t$2) => {
  const init$3 = { $: "Open", a: "ada" };
  let $model$4 = init$3;
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
    let $t$14;
    {
      let $t$13;
      if ($model$4.$ === "Open") {
        const name$2 = $model$4.a;
        $t$13 = [name$2];
      } else {
        $t$13 = null;
      }
      $t$14 = $t$13;
    }
    const $t$15 = $t$14[0];
    if ($t$15 !== $r$12.s0) {
      $r$12.w1.data = $t$15;
      $r$12.s0 = $t$15;
    }
  };
  const $A$16 = ($u$18) => {
    const $e$19 = $T$5.cloneNode(true);
    const $w$20 = $e$19.firstChild;
    const $w$21 = $w$20.firstChild;
    const $r$22 = { e: $e$19, w1: $w$21, s0: Direct$unset };
    $g$11($r$22);
    return $r$22;
  };
  const $A$17 = ($u$23) => {
    const $e$24 = $T$6.cloneNode(true);
    const $w$25 = $e$24.firstChild;
    const $r$26 = { e: $e$24 };
    return $r$26;
  };
  const $B$27 = Direct$branch($w$8, null, [$A$16, $A$17]);
  const $patchAll$28 = () => {
  };
  const $hRename$35 = () => {
    let $t$29;
    if ($model$4.$ === "Open") {
      const name$5 = $model$4.a;
      $t$29 = { $: "Open", a: Basics$append(name$5, "!") };
    } else {
      $t$29 = $model$4;
    }
    $model$4 = $t$29;
    {
      let $t$34;
      {
        let $t$33;
        if ($model$4.$ === "Open") {
          const name$7 = $model$4.a;
          $t$33 = 0;
        } else {
          $t$33 = 1;
        }
        $t$34 = $t$33;
      }
      const $n$32 = $t$34;
      if ($n$32 !== $B$27.k) {
        Direct$arm($B$27, $n$32, null);
      } else {
        if ($B$27.k === 0) {
          const $a$30 = $B$27.i;
          $g$11($a$30);
        }
      }
    }
  };
  const $hClose$41 = () => {
    $model$4 = Branch$Closed;
    {
      let $t$40;
      {
        let $t$39;
        if ($model$4.$ === "Open") {
          const name$12 = $model$4.a;
          $t$39 = 0;
        } else {
          $t$39 = 1;
        }
        $t$40 = $t$39;
      }
      const $n$38 = $t$40;
      if ($n$38 !== $B$27.k) {
        Direct$arm($B$27, $n$38, null);
      } else {
        if ($B$27.k === 0) {
          const $a$36 = $B$27.i;
          $g$11($a$36);
        }
      }
    }
    $patchAll$28();
  };
  {
    Direct$on($w$9, "click", $hRename$35);
    Direct$on($w$10, "click", $hClose$41);
  }
  {
    let $t$46;
    {
      let $t$45;
      if ($model$4.$ === "Open") {
        const name$18 = $model$4.a;
        $t$45 = 0;
      } else {
        $t$45 = 1;
      }
      $t$46 = $t$45;
    }
    const $n$44 = $t$46;
    Direct$arm($B$27, $n$44, null);
  }
  $root$1.append($r$7);
  const $check$48 = ($r$47) => {
  };
  const $check$53 = ($r$49) => {
    let $t$51;
    {
      let $t$50;
      if ($model$4.$ === "Open") {
        const name$20 = $model$4.a;
        $t$50 = [name$20];
      } else {
        $t$50 = null;
      }
      $t$51 = $t$50;
    }
    const $t$52 = $t$51[0];
    if (!Direct$same($t$52, $r$49.s0)) {
      Direct$wrong("the text hole at Branch.beni:47:20", $r$49.s0, $t$52);
    }
    if ($r$49.w1.data !== `${$t$52}`) {
      Direct$wrong("the text hole at Branch.beni:47:20 in the document", $r$49.w1.data, `${$t$52}`);
    }
  };
  Direct$verify(() => {
    {
      let $t$56;
      {
        let $t$55;
        if ($model$4.$ === "Open") {
          const name$24 = $model$4.a;
          $t$55 = 0;
        } else {
          $t$55 = 1;
        }
        $t$56 = $t$55;
      }
      const $n$54 = $t$56;
      if ($n$54 !== $B$27.k) {
        Direct$wrong("the arm of the branch at Branch.beni:45:9", $B$27.k, $n$54);
      } else {
        if ($B$27.k === 0) {
          $check$53($B$27.i);
        }
        if ($B$27.k === 1) {
          $check$48($B$27.i);
        }
      }
    }
  });
});
export { Branch$main };
//# sourceMappingURL=Branch.mjs.map
