import { Inline$root, Inline$own, Inline$text, Inline$entry, Inline$pass, Inline$on, Inline$first } from "./_platform/Inline.mjs";
const NoConstructorFile$main = ($id$1) => {
  const $root$2 = Inline$root(undefined);
  const $init$3 = 0;
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", "<button>");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $table$6 = [[[]]];
  Inline$entry(() => {
    Inline$text($node$5, `${$model$4}`);
  }, $table$6[0][0]);
  Inline$on($node$5, () => {
    const $before$7 = $model$4;
    $model$4 = $before$7 + 1;
    Inline$pass($table$6[0][0]);
  });
  Inline$first();
};
export { NoConstructorFile$main };
//# sourceMappingURL=NoConstructorFile.mjs.map
