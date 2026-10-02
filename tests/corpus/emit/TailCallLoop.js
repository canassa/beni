import { Node$printLines } from "./_platform/Node.mjs";
const TailCallLoop$countUp = (n$1, acc$2, step$3) => {
  while (!(n$1 <= 0)) {
    n$1 = n$1 - 1;
    acc$2 = acc$2 + step$3;
  }
  return acc$2;
};
const TailCallLoop$plain = (n$1) => n$1 <= 0 ? 0 : 1 + TailCallLoop$plain(n$1 - 1);
const TailCallLoop$main = Node$printLines([]);
export { TailCallLoop$main, TailCallLoop$countUp, TailCallLoop$plain };
//# sourceMappingURL=TailCallLoop.mjs.map
