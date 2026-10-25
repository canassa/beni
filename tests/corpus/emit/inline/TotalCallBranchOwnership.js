import { Inline$root, Inline$own, Inline$when, Inline$text, Inline$entry, Inline$passes, Inline$on, Inline$first } from "./_platform/Inline.mjs";
import { List$push } from "./_core/List.mjs";
const TotalCallBranchOwnership$main = ($id$1) => {
  const $root$2 = Inline$root("root");
  const $init$3 = false;
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", "<main><section data-arm=left><p></section><section data-arm=right><p></section><button>Toggle");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[[], []]];
  Inline$entry(() => {
    let $arm$9;
    let $value$11;
    let $selected$12;
    let $value$15;
    let $value$16;
    let $selected$17;
    let $value$20;
    {
      const $t$8 = [1];
      const $t$10 = $model$4 ? 0 : 1;
      $arm$9 = $t$10;
      $value$11 = $arm$9;
      $selected$12 = !$arm$9;
      if ($selected$12) {
        const $t$13 = List$push($t$8, 2);
        const $t$14 = $t$13.length;
        $value$15 = `${$t$14}`;
      }
      $value$16 = !$arm$9;
      $selected$17 = $arm$9;
      if ($selected$17) {
        const $t$18 = List$push($t$8, 3);
        const $t$19 = $t$18.length;
        $value$20 = `${$t$19}`;
      }
    }
    Inline$when($elements$6[0], $value$11);
    if ($selected$12) {
      Inline$text($elements$6[1], $value$15);
    }
    Inline$when($elements$6[2], $value$16);
    if ($selected$17) {
      Inline$text($elements$6[3], $value$20);
    }
  }, $table$7[0][1]);
  Inline$on($elements$6[4], () => {
    const $value$21 = "Toggle";
    const $before$22 = $model$4;
    $model$4 = !$before$22;
    Inline$passes($table$7[0]);
  });
  Inline$first();
};
export { TotalCallBranchOwnership$main };
//# sourceMappingURL=TotalCallBranchOwnership.mjs.map
