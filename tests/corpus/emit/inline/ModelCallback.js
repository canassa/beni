import { Inline$defaultRoot, Inline$root, Inline$own, Inline$bucket, Inline$text, Inline$entry, Inline$pass, Inline$unchanged, Inline$guarded, Inline$first, Inline$client } from "./_platform/Inline.mjs";
const ModelCallback$main = Inline$client(($id$1) => {
  const $root$2 = Inline$root(Inline$defaultRoot(null));
  const $init$3 = { n: 0, next: (n$1) => n$1 + 1 };
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", "<main><button>add</button><p>");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[Inline$bucket(null)]];
  Inline$entry(() => {
    const $t$8 = $model$4.n;
    Inline$text($elements$6[1], `${$t$8}`);
  }, [$table$7[0][0]]);
  const $listener$11 = () => {
    const $value$9 = "Add";
    const $before$10 = $model$4;
    $before$10.n = $before$10.next($before$10.n), $before$10;
    Inline$pass($table$7[0][0]);
  };
  const $reader$12 = Inline$unchanged;
  $elements$6[0].addEventListener("click", ($event$13) => {
    Inline$guarded($listener$11, $event$13, $reader$12);
  });
  Inline$first();
});
export { ModelCallback$main };
//# sourceMappingURL=ModelCallback.mjs.map
