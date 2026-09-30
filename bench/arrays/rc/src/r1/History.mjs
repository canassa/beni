import { Array$initialize, Array$set, Array$length, Array$foldl } from "./_core/Array.mjs";
import { List$take, List$cons } from "./_core/List.mjs";
import { $dup } from "rc-rt";
import { Basics$modBy, Basics$add, Basics$mul, Basics$sub, Basics$negate } from "./_core/Basics.mjs";
// research/42 R1 by hand. History holds an Array (O5); `past` is a List, uncounted.
const History$drop = (h) => { if (--h.rc === 0) h.current.rc--; }; // R1
const History$start = (n$1) => ({ rc: 1, current: Array$initialize(n$1, (i$2) => i$2), past: { $: 0, a: null, b: null } });
// h.current is consumed twice (by `set` and by `::`): one token is taken from h, one is a dup,
// so `set` always sees a shared array and copies — the history keeps the old version (research 38 §15.8)
const History$edit = (h$1, i$2, v$3) => {
  const u$ = h$1.rc === 1;
  const cur$ = u$ ? h$1.current : $dup(h$1.current);
  if (!u$) History$drop(h$1); // R1
  $dup(cur$);
  return { rc: 1, current: Array$set(cur$, i$2, v$3), past: List$take(List$cons(cur$, h$1.past), 100) };
};
const History$undo = (h$1) => {
  const $t$1 = h$1.past;
  if ($t$1.$ === 0) {
    return h$1;
  } else {
    // read out of an uncounted cons cell: a new holder
    const prev$2 = $dup($t$1.a);
    const rest$3 = $t$1.b;
    History$drop(h$1); // R1
    return { rc: 1, current: prev$2, past: rest$3 };
  }
};
const History$editsHelp = ($in$0, $in$1, k$3, seed$4) => {
  History$editsHelp: while (true) {
    const h$1 = $in$0;
    const j$2 = $in$1;
    if (j$2 >= k$3) {
      return h$1;
    } else {
      $in$0 = History$edit(h$1, Basics$modBy(Basics$add(seed$4, Basics$mul(j$2, 7919)), Array$length(h$1.current)), Basics$sub(Basics$sub(Basics$negate(1), seed$4), j$2));
      $in$1 = Basics$add(j$2, 1);
      continue History$editsHelp;
    }
  }
};
const History$edits = (h$1, k$2, seed$3) => History$editsHelp(h$1, 0, k$2, seed$3);
const History$sum = (h$1) => Array$foldl(h$1.current, 0, (v$2, s$3) => Basics$add(s$3, v$2));
export { History$start, History$edit, History$undo, History$edits, History$sum };
