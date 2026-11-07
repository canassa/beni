import { Inline$root, Inline$own, Inline$text, Inline$entry, Inline$pass, Inline$on, Inline$first } from "./_platform/Inline.mjs";
const ModelCallback$main = ($id$1) => {
  const $root$2 = Inline$root(undefined);
  const $init$3 = { n: 0, next: (n$1) => n$1 + 1 };
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", "<main><button>add</button><p>");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[[]]];
  Inline$entry(() => {
    const $t$8 = $model$4.n;
    Inline$text($elements$6[1], `${$t$8}`);
  }, $table$7[0][0]);
  Inline$on($elements$6[0], () => {
    const $value$9 = "Add";
    const $before$10 = $model$4;
    $before$10.n = $before$10.next($before$10.n), $before$10;
    Inline$pass($table$7[0][0]);
  });
  Inline$first();
};
export { ModelCallback$main };
//# sourceMappingURL=ModelCallback.mjs.map
