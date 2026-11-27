import { Inline$root, Inline$caught, Inline$take, Inline$when, Inline$entry, Inline$pass, Inline$onTaken, Inline$first, Inline$deliver } from "./_platform/Inline.mjs";
import { Widget$view$$html$0, Widget$update$$arm$0, Widget$view$$root$0 } from "./Widget.mjs";
const HydratedPiece$main = ($id$1) => {
  const $root$2 = Inline$root(undefined);
  const $init$3 = { open: false, w: { on: false } };
  const $cell$5 = [$init$3];
  Inline$caught($root$2);
  const $elements$6 = Inline$take($root$2, `<main><button>Toggle</button><p>Open</p>${Widget$view$$html$0}`, [2, 1, 0, 5, 1, 3], "main button p section button strong");
  const $elements$7 = $elements$6.slice(4, 6);
  const $table$8 = [[[]], [[]]];
  Inline$entry(() => {
    const model$1 = $cell$5[0];
    const $t$10 = model$1.open ? 0 : 1;
    const $arm$9 = $t$10;
    Inline$when($elements$6[2], $arm$9);
  }, $table$8[0][0]);
  Inline$onTaken($elements$6[1], () => {
    const model$2 = $cell$5[0];
    const $before$11 = $cell$5[0];
    $before$11.open = !$before$11.open;
    Inline$pass($table$8[0][0]);
  });
  const model$6 = $cell$5[0];
  Widget$view$$root$0($elements$7, $cell$5, $table$8[1], () => {
    const $before$12 = $cell$5[0];
    const $t$13 = $before$12.w;
    $before$12.w = Widget$update$$arm$0($t$13);
    Inline$pass($table$8[1][0]);
  });
  Inline$first();
  Inline$deliver($elements$6[0]);
};
export { HydratedPiece$main };
//# sourceMappingURL=HydratedPiece.mjs.map
