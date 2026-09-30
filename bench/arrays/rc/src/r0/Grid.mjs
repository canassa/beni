import { Array$initialize, Array$get, Array$setU, Array$foldl } from "./_core/Array.mjs";
import { Basics$mul, Basics$modBy, Basics$add, Basics$sub, Basics$idiv } from "./_core/Basics.mjs";
const Grid$make = (w$1, h$2) => ({ cells: Array$initialize(Basics$mul(w$1, h$2), (i$3) => Basics$modBy(Basics$mul(i$3, 7), 5) === 0 ? 1 : 0), h: h$2, w: w$1 });
const Grid$cell = (g$1, x$2, y$3) => {
  const $t$1 = Array$get(g$1.cells, Basics$add(Basics$mul(Basics$modBy(y$3, g$1.h), g$1.w), Basics$modBy(x$2, g$1.w)));
  if ($t$1.$ === "Just") {
    const v$4 = $t$1.a;
    return v$4;
  } else {
    return 0;
  }
};
const Grid$neighbours = (g$1, x$2, y$3) => Basics$add(Basics$add(Basics$add(Basics$add(Basics$add(Basics$add(Basics$add(Grid$cell(g$1, Basics$sub(x$2, 1), Basics$sub(y$3, 1)), Grid$cell(g$1, x$2, Basics$sub(y$3, 1))), Grid$cell(g$1, Basics$add(x$2, 1), Basics$sub(y$3, 1))), Grid$cell(g$1, Basics$sub(x$2, 1), y$3)), Grid$cell(g$1, Basics$add(x$2, 1), y$3)), Grid$cell(g$1, Basics$sub(x$2, 1), Basics$add(y$3, 1))), Grid$cell(g$1, x$2, Basics$add(y$3, 1))), Grid$cell(g$1, Basics$add(x$2, 1), Basics$add(y$3, 1)));
// research/42 R0 by hand. Summary (S2): `g.cells` is CONSUMED-UNIQUE in tickHelp and so in tick:
// the cell reads borrow g, and the record update is the last use of g and of its cells.
const Grid$tickHelp = ($in$0, $in$1, k$3, seed$4) => {
  Grid$tickHelp: while (true) {
    const g$1 = $in$0;
    const j$2 = $in$1;
    if (j$2 >= k$3) {
      return g$1;
    } else {
      const i$5 = Basics$modBy(Basics$add(seed$4, Basics$mul(j$2, 7919)), Basics$mul(g$1.w, g$1.h));
      const x$6 = Basics$modBy(i$5, g$1.w);
      const y$7 = Basics$idiv(i$5, g$1.w);
      const n$8 = Grid$neighbours(g$1, x$6, y$7);
      const v$9 = Basics$add(Basics$add(Grid$cell(g$1, x$6, y$7), 1), Basics$modBy(n$8, 2));
      $in$0 = { ...g$1, cells: Array$setU(g$1.cells, i$5, v$9) };
      $in$1 = Basics$add(j$2, 1);
      continue Grid$tickHelp;
    }
  }
};
const Grid$tick = (g$1, k$2, seed$3) => Grid$tickHelp(g$1, 0, k$2, seed$3);
const Grid$population = (g$1) => Array$foldl(g$1.cells, 0, (v$2, s$3) => Basics$add(s$3, v$2));
export { Grid$make, Grid$tick, Grid$population };
