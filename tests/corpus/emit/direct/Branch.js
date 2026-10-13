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
    const $t$13 = $r$12.a;
    const $t$14 = $t$13[1];
    if ($t$14 !== $r$12.s0) {
      $r$12.w1.data = $t$14;
      $r$12.s0 = $t$14;
    }
  };
  const $A$15 = ($u$17, $b$18, $a$19) => {
    const $e$20 = $T$5.cloneNode(true);
    const $w$21 = $e$20.firstChild;
    const $w$22 = $w$21.firstChild;
    const $r$23 = { e: $e$20, a: $a$19, w1: $w$22, s0: Direct$unset };
    $g$11($r$23);
    return $r$23;
  };
  const $A$16 = ($u$24, $b$25, $a$26) => {
    const $e$27 = $T$6.cloneNode(true);
    const $w$28 = $e$27.firstChild;
    const $r$29 = { e: $e$27, a: $a$26 };
    return $r$29;
  };
  const $B$30 = Direct$branch($w$8, null, [$A$15, $A$16]);
  const $patchAll$31 = () => {
  };
  const $hRename$39 = () => {
    let $t$32;
    if ($model$4.$ === "Open") {
      const name$5 = $model$4.a;
      $t$32 = { $: "Open", a: Basics$append(name$5, "!") };
    } else {
      $t$32 = $model$4;
    }
    $model$4 = $t$32;
    {
      let $t$38;
      {
        let $t$37;
        if ($model$4.$ === "Open") {
          const name$7 = $model$4.a;
          $t$37 = [0, name$7];
        } else {
          $t$37 = [1];
        }
        $t$38 = $t$37;
      }
      const $a$36 = $t$38;
      const $n$35 = $a$36[0];
      if ($n$35 !== $B$30.k) {
        Direct$arm($B$30, $n$35, null, $a$36);
      } else {
        if ($B$30.i !== null) {
          $B$30.i.a = $a$36;
        }
        {
          if ($B$30.k === 0) {
            const $a$33 = $B$30.i;
            $g$11($a$33);
          }
        }
      }
    }
  };
  const $hClose$46 = () => {
    $model$4 = Branch$Closed;
    {
      let $t$45;
      {
        let $t$44;
        if ($model$4.$ === "Open") {
          const name$12 = $model$4.a;
          $t$44 = [0, name$12];
        } else {
          $t$44 = [1];
        }
        $t$45 = $t$44;
      }
      const $a$43 = $t$45;
      const $n$42 = $a$43[0];
      if ($n$42 !== $B$30.k) {
        Direct$arm($B$30, $n$42, null, $a$43);
      } else {
        if ($B$30.i !== null) {
          $B$30.i.a = $a$43;
        }
        {
          if ($B$30.k === 0) {
            const $a$40 = $B$30.i;
            $g$11($a$40);
          }
        }
      }
    }
    $patchAll$31();
  };
  {
    Direct$on($w$9, "click", $hRename$39);
    Direct$on($w$10, "click", $hClose$46);
  }
  {
    let $t$52;
    {
      let $t$51;
      if ($model$4.$ === "Open") {
        const name$18 = $model$4.a;
        $t$51 = [0, name$18];
      } else {
        $t$51 = [1];
      }
      $t$52 = $t$51;
    }
    const $a$50 = $t$52;
    const $n$49 = $a$50[0];
    Direct$arm($B$30, $n$49, null, $a$50);
  }
  $root$1.append($r$7);
  const $check$55 = ($r$53, $a$54) => {
  };
  const $check$60 = ($r$56, $a$57) => {
    const $t$58 = $a$57;
    const $t$59 = $t$58[1];
    if (!Direct$same($t$59, $r$56.s0)) {
      Direct$wrong("the text hole at Branch.beni:47:20", $r$56.s0, $t$59);
    }
    if ($r$56.w1.data !== `${$t$59}`) {
      Direct$wrong("the text hole at Branch.beni:47:20 in the document", $r$56.w1.data, `${$t$59}`);
    }
  };
  Direct$verify(() => {
    {
      let $t$64;
      {
        let $t$63;
        if ($model$4.$ === "Open") {
          const name$24 = $model$4.a;
          $t$63 = [0, name$24];
        } else {
          $t$63 = [1];
        }
        $t$64 = $t$63;
      }
      const $a$62 = $t$64;
      const $n$61 = $a$62[0];
      if ($n$61 !== $B$30.k) {
        Direct$wrong("the arm of the branch at Branch.beni:45:9", $B$30.k, $n$61);
      } else {
        if ($B$30.k === 0) {
          $check$60($B$30.i, $a$62);
        }
        if ($B$30.k === 1) {
          $check$55($B$30.i, $a$62);
        }
      }
    }
  });
});
export { Branch$main };
//# sourceMappingURL=Branch.mjs.map
