import { Inline$root, Inline$own, Inline$text, Inline$entry, Inline$pass, Inline$on, Inline$first } from "./_platform/Inline.mjs";
import { Cmd$none } from "./_platform/Cmd.mjs";
import { Log$annotate, Log$minimum, Log$debug, Log$span, Log$info } from "./_core/Log.mjs";
const LogScopeInUpdate$main = ($id$1) => {
  const $root$2 = Inline$root(undefined);
  const $init$3 = { a: { n: 0 }, b: Cmd$none };
  let $model$4 = $init$3.a;
  $root$2.insertAdjacentHTML("beforeend", "<main><button id=annotated>annotated</button><button id=spanned>spanned</button><p>");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[[]]];
  Inline$entry(() => {
    const $t$8 = $model$4.n;
    Inline$text($elements$6[2], `${$t$8}`);
  }, $table$7[0][0]);
  Inline$on($elements$6[0], () => {
    const $before$9 = $model$4;
    $before$9.n = $before$9.n + 1;
    const next$6 = $before$9;
    Log$annotate("request", "p1", () => Log$minimum("Debug", () => {
      Log$debug("in the arm");
      return { a: next$6, b: Cmd$none };
    }));
    Inline$pass($table$7[0][0]);
  });
  Inline$on($elements$6[1], () => {
    const $before$10 = $model$4;
    $before$10.n = $before$10.n + 1;
    const next$9 = $before$10;
    Log$span("save", () => {
      Log$info("in a span");
      return { a: next$9, b: Cmd$none };
    });
    Inline$pass($table$7[0][0]);
  });
  Inline$first();
};
export { LogScopeInUpdate$main };
//# sourceMappingURL=LogScopeInUpdate.mjs.map
