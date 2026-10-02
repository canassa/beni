import { List$append } from "./_core/List.mjs";
import { Basics$append } from "./_core/Basics.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const AppendOperator$lists = (a$1, b$2) => List$append(a$1, b$2);
const AppendOperator$spread = (a$1, b$2) => List$append(a$1, b$2);
const AppendOperator$strings = (a$1, b$2) => Basics$append(a$1, b$2);
const AppendOperator$generic = (a$1, b$2) => Basics$append(a$1, b$2);
const AppendOperator$grow = (n$1, acc$2) => {
  while (!(n$1 <= 0)) {
    const $t$1 = n$1 - 1;
    acc$2 = List$append(acc$2, [n$1]);
    n$1 = $t$1;
  }
  return acc$2;
};
const AppendOperator$main = Node$printLines([]);
export { AppendOperator$main, AppendOperator$lists, AppendOperator$spread, AppendOperator$strings, AppendOperator$generic, AppendOperator$grow };
//# sourceMappingURL=AppendOperator.mjs.map
