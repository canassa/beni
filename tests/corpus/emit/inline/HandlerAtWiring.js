import { Inline$namedRoot, Inline$root, Inline$own, Inline$bucket, Inline$text, Inline$entry, Inline$pass, Inline$unchanged, Inline$guarded, Inline$first, Inline$client } from "./_platform/Inline.mjs";
const HandlerAtWiring$main = Inline$client(($id$1) => {
  const $root$2 = Inline$root(Inline$namedRoot("root"));
  const $init$3 = 0;
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", "<main><output></output><button>one</button><button>two");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[Inline$bucket(null)]];
  Inline$entry(() => {
    Inline$text($elements$6[0], `${$model$4}`);
  }, [$table$7[0][0]]);
  const $listener$12 = () => {
    const $value$8 = 1;
    const $before$9 = $model$4;
    $model$4 = $before$9 + $value$8;
    Inline$pass($table$7[0][0]);
  };
  const $reader$13 = Inline$unchanged;
  $elements$6[1].addEventListener("click", ($event$14) => {
    Inline$guarded($listener$12, $event$14, $reader$13);
  });
  const $listener$15 = () => {
    const $value$10 = 2;
    const $before$11 = $model$4;
    $model$4 = $before$11 + $value$10;
    Inline$pass($table$7[0][0]);
  };
  const $reader$16 = Inline$unchanged;
  $elements$6[2].addEventListener("click", ($event$17) => {
    Inline$guarded($listener$15, $event$17, $reader$16);
  });
  Inline$first();
});
export { HandlerAtWiring$main };
//# sourceMappingURL=HandlerAtWiring.mjs.map
