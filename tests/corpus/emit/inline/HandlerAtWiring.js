import { Inline$root, Inline$own, Inline$text, Inline$on } from "./_platform/Inline.mjs";
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
  const $bind$7 = () => {
    Inline$text($elements$6[0], `${$model$4}`);
  };
  $bind$7();
  Inline$on($elements$6[1], () => {
    const $value$8 = 1;
    const $before$9 = $model$4;
    $model$4 = $before$9 + $value$8;
    $bind$7();
  });
  Inline$on($elements$6[2], () => {
    const $value$10 = 2;
    const $before$11 = $model$4;
    $model$4 = $before$11 + $value$10;
    $bind$7();
  });
};
export { HandlerAtWiring$main };
//# sourceMappingURL=HandlerAtWiring.mjs.map
