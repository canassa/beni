import { Inline$root, Inline$caught, Inline$take, Inline$when, Inline$entry, Inline$pass, Inline$onTaken, Inline$first, Inline$deliver } from "./_platform/Inline.mjs";
const HydratingMount$main = ($id$1) => {
  const $root$2 = Inline$root(undefined);
  const $init$3 = { open: false };
  let $model$4 = $init$3;
  Inline$caught($root$2);
  const $elements$5 = Inline$take($root$2, "<div><h1>Title</h1><p>Open", [2, 1, 0], "div h1 p");
  const $table$6 = [[[]]];
  Inline$entry(() => {
    const $t$8 = $model$4.open ? 0 : 1;
    const $arm$7 = $t$8;
    Inline$when($elements$5[2], $arm$7);
  }, $table$6[0][0]);
  Inline$onTaken($elements$5[0], () => {
    const $before$9 = $model$4;
    $before$9.open = !$before$9.open;
    Inline$pass($table$6[0][0]);
  });
  Inline$first();
  Inline$deliver($elements$5[0]);
};
export { HydratingMount$main };
//# sourceMappingURL=HydratingMount.mjs.map
