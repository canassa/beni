import { List$push, List$append, List$update, List$set } from "./_core/List.mjs";
import { Inline$root, Inline$own, Inline$when, Inline$text, Inline$entry, Inline$pass, Inline$on, Inline$first } from "./_platform/Inline.mjs";
const TotalCallBranchForms$bump = (xs$1) => List$push(xs$1, 4);
const TotalCallBranchForms$main = ($id$1) => {
  const $root$2 = Inline$root("root");
  const $init$3 = 0;
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", "<main><section data-arm=dot><p></section><section data-arm=append><p></section><section data-arm=update><p></section><section data-arm=set><p></section><section data-arm=helper><p></section><button>Next");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[[]]];
  Inline$entry(() => {
    let $arm$9;
    let $value$12;
    let $selected$13;
    let $value$16;
    let $value$17;
    let $selected$18;
    let $value$21;
    let $value$22;
    let $selected$23;
    let $value$26;
    let $value$27;
    let $selected$28;
    let $value$31;
    let $value$32;
    let $selected$33;
    let $value$36;
    {
      const $t$8 = [1];
      let $t$11;
      {
        let $t$10;
        $c$0: {
          switch ($model$4) {
            case 0:
              {
                $t$10 = 0;
                break $c$0;
              }
            case 1:
              {
                $t$10 = 1;
                break $c$0;
              }
            case 2:
              {
                $t$10 = 2;
                break $c$0;
              }
            case 3:
              {
                $t$10 = 3;
                break $c$0;
              }
            default:
              {
                $t$10 = 4;
                break $c$0;
              }
          }
        }
        $t$11 = $t$10;
      }
      $arm$9 = $t$11;
      $value$12 = $arm$9 !== 0;
      $selected$13 = $arm$9 === 0;
      if ($selected$13) {
        const $t$14 = List$push($t$8, 2);
        const $t$15 = $t$14.length;
        $value$16 = `${$t$15}`;
      }
      $value$17 = $arm$9 !== 1;
      $selected$18 = $arm$9 === 1;
      if ($selected$18) {
        const $t$19 = List$append($t$8, [3]);
        const $t$20 = $t$19.length;
        $value$21 = `${$t$20}`;
      }
      $value$22 = $arm$9 !== 2;
      $selected$23 = $arm$9 === 2;
      if ($selected$23) {
        const $t$24 = List$update($t$8, 0, (x$4) => x$4 + 1);
        const $t$25 = $t$24.length;
        $value$26 = `${$t$25}`;
      }
      $value$27 = $arm$9 !== 3;
      $selected$28 = $arm$9 === 3;
      if ($selected$28) {
        const $t$29 = List$set($t$8, 0, 9);
        const $t$30 = $t$29.length;
        $value$31 = `${$t$30}`;
      }
      $value$32 = $arm$9 !== 4;
      $selected$33 = $arm$9 === 4;
      if ($selected$33) {
        const $t$34 = TotalCallBranchForms$bump($t$8);
        const $t$35 = $t$34.length;
        $value$36 = `${$t$35}`;
      }
    }
    Inline$when($elements$6[0], $value$12);
    if ($selected$13) {
      Inline$text($elements$6[1], $value$16);
    }
    Inline$when($elements$6[2], $value$17);
    if ($selected$18) {
      Inline$text($elements$6[3], $value$21);
    }
    Inline$when($elements$6[4], $value$22);
    if ($selected$23) {
      Inline$text($elements$6[5], $value$26);
    }
    Inline$when($elements$6[6], $value$27);
    if ($selected$28) {
      Inline$text($elements$6[7], $value$31);
    }
    Inline$when($elements$6[8], $value$32);
    if ($selected$33) {
      Inline$text($elements$6[9], $value$36);
    }
  }, $table$7[0][0]);
  Inline$on($elements$6[10], () => {
    const $value$37 = "Next";
    const $before$38 = $model$4;
    $model$4 = $before$38 + 1;
    Inline$pass($table$7[0][0]);
  });
  Inline$first();
};
export { TotalCallBranchForms$main };
//# sourceMappingURL=TotalCallBranchForms.mjs.map
