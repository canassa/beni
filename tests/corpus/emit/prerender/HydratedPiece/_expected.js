import { Inline$root, Inline$take, Inline$when, Inline$entry, Inline$pass, Inline$on, Inline$first } from "./_platform/Inline.mjs";
import { Widget$view$$html$0, Widget$view$$root$0 } from "./Widget.mjs";
const HydratedPiece$main = ($id$1) => {
  const $root$2 = Inline$root(undefined);
  const $init$3 = { open: false, w: { on: false } };
  let $model$4 = $init$3;
  const $elements$5 = Inline$take($root$2, `<main><button>Toggle</button><p>Open</p>${Widget$view$$html$0}`, [2, 1, 0, 5, 1, 3], "main button p section button strong");
  const $elements$6 = $elements$5.slice(4, 6);
  const $table$7 = [[[]], [[]]];
  Inline$entry(() => {
    const $t$9 = $model$4.open ? 0 : 1;
    const $arm$8 = $t$9;
    Inline$when($elements$5[2], $arm$8);
  }, $table$7[0][0]);
  Inline$on($elements$5[1], () => {
    const $before$10 = $model$4;
    $before$10.open = !$before$10.open;
    Inline$pass($table$7[0][0]);
  });
  Widget$view$$root$0($elements$6, $model$4.w, $table$7[1]);
  Inline$first();
};
export { HydratedPiece$main };
//# sourceMappingURL=HydratedPiece.mjs.map
