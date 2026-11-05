import { Inline$defaultRoot, Inline$root, Inline$own, Inline$bucket, Inline$text, Inline$entry, Inline$pass, Inline$unchanged, Inline$guarded, Inline$first, Inline$client } from "./_platform/Inline.mjs";
import { Cmd$none } from "./_platform/Cmd.mjs";
import { Log$annotate, Log$minimum, Log$debug, Log$span, Log$info } from "./_core/Log.mjs";
const LogScopeInUpdate$main = Inline$client(($id$1) => {
  const $root$2 = Inline$root(Inline$defaultRoot(null));
  const $init$3 = { a: { n: 0 }, b: Cmd$none };
  let $model$4 = $init$3.a;
  $root$2.insertAdjacentHTML("beforeend", "<main><button id=annotated>annotated</button><button id=spanned>spanned</button><p>");
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $table$7 = [[Inline$bucket(null)]];
  Inline$entry(() => {
    const $t$8 = $model$4.n;
    Inline$text($elements$6[2], `${$t$8}`);
  }, [$table$7[0][0]]);
  const $listener$11 = () => {
    const $before$9 = $model$4;
    $before$9.n = $before$9.n + 1;
    const next$6 = $before$9;
    Log$annotate("request", "p1", () => Log$minimum("Debug", () => {
      Log$debug("in the arm");
      return { a: next$6, b: Cmd$none };
    }));
    Inline$pass($table$7[0][0]);
  };
  const $reader$12 = Inline$unchanged;
  $elements$6[0].addEventListener("click", ($event$13) => {
    Inline$guarded($listener$11, $event$13, $reader$12);
  });
  const $listener$14 = () => {
    const $before$10 = $model$4;
    $before$10.n = $before$10.n + 1;
    const next$9 = $before$10;
    Log$span("save", () => {
      Log$info("in a span");
      return { a: next$9, b: Cmd$none };
    });
    Inline$pass($table$7[0][0]);
  };
  const $reader$15 = Inline$unchanged;
  $elements$6[1].addEventListener("click", ($event$16) => {
    Inline$guarded($listener$14, $event$16, $reader$15);
  });
  Inline$first();
});
export { LogScopeInUpdate$main };
//# sourceMappingURL=LogScopeInUpdate.mjs.map
