import { Inline$root, Inline$own, Inline$text, Inline$entry, Inline$pass, Inline$on, Inline$first } from "./_platform/Inline.mjs";
const HandlerAtWiring$main = ($id$1) => {
  const $root$2 = Inline$root("root");
  const $init$3 = 0;
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", "<main><output></output><button>one</button><button>two");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[[]]];
  Inline$entry(() => {
    Inline$text($elements$6[0], `${$model$4}`);
  }, $table$7[0][0]);
  Inline$on($elements$6[1], () => {
    const $value$8 = 1;
    const $before$9 = $model$4;
    $model$4 = $before$9 + $value$8;
    Inline$pass($table$7[0][0]);
  });
  Inline$on($elements$6[2], () => {
    const $value$10 = 2;
    const $before$11 = $model$4;
    $model$4 = $before$11 + $value$10;
    Inline$pass($table$7[0][0]);
  });
  Inline$first();
};
export { HandlerAtWiring$main };
//# sourceMappingURL=HandlerAtWiring.mjs.map
