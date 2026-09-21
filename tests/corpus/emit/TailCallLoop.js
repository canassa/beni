import { Basics$sub, Basics$add } from "./_core/Basics.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const TailCallLoop$countUp = ($in$0, $in$1, step$3) => {
  TailCallLoop$countUp: while (true) {
    const n$1 = $in$0;
    const acc$2 = $in$1;
    if (n$1 <= 0) {
      return acc$2;
    } else {
      $in$0 = Basics$sub(n$1, 1);
      $in$1 = Basics$add(acc$2, step$3);
      continue TailCallLoop$countUp;
    }
  }
};
const TailCallLoop$plain = (n$1) => n$1 <= 0 ? 0 : Basics$add(1, TailCallLoop$plain(Basics$sub(n$1, 1)));
const TailCallLoop$main = Node$printLines({ $: 0, a: null, b: null });
export { TailCallLoop$main, TailCallLoop$countUp, TailCallLoop$plain };
