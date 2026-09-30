import { Array$get, Array$initialize } from "./_core/Array.mjs";
import { Basics$add, Basics$mul, Basics$modBy, Basics$idiv, Basics$sub } from "./_core/Basics.mjs";
import { $dup } from "rc-rt";
const Life$cell = (g$1, x$2, y$3) => {
  const $t$1 = Array$get(g$1.cells, Basics$add(Basics$mul(Basics$modBy(y$3, g$1.h), g$1.w), Basics$modBy(x$2, g$1.w)));
  if ($t$1.$ === "Just") {
    const v$4 = $t$1.a;
    return v$4;
  } else {
    return 0;
  }
};
const Life$alive = (g$1, i$2) => {
  const x$3 = Basics$modBy(i$2, g$1.w);
  const y$4 = Basics$idiv(i$2, g$1.w);
  const n$5 = Basics$add(Basics$add(Basics$add(Basics$add(Basics$add(Basics$add(Basics$add(Life$cell(g$1, Basics$sub(x$3, 1), Basics$sub(y$4, 1)), Life$cell(g$1, x$3, Basics$sub(y$4, 1))), Life$cell(g$1, Basics$add(x$3, 1), Basics$sub(y$4, 1))), Life$cell(g$1, Basics$sub(x$3, 1), y$4)), Life$cell(g$1, Basics$add(x$3, 1), y$4)), Life$cell(g$1, Basics$sub(x$3, 1), Basics$add(y$4, 1))), Life$cell(g$1, x$3, Basics$add(y$4, 1))), Life$cell(g$1, Basics$add(x$3, 1), Basics$add(y$4, 1)));
  return n$5 === 3 || n$5 === 2 && Life$cell(g$1, x$3, y$4) === 1 ? 1 : 0;
};
// research/42 R1 by hand: the lambda captures g, and an uncounted JavaScript closure keeps what
// it captures forever (O2), so g gains a holder that is never released
const Life$step = (g$1) => {
  $dup(g$1);
  const r$ = { ...g$1, rc: 1, cells: Array$initialize(Basics$mul(g$1.w, g$1.h), (i$2) => Life$alive(g$1, i$2)) };
  if (--g$1.rc === 0) g$1.cells.rc--; // R1
  return r$;
};
export { Life$step };
