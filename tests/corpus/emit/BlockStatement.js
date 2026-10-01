import { Debug$log } from "./_core/Debug.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const BlockStatement$say = (s$1) => {
  Debug$log("say", s$1);
};
const BlockStatement$statement = (c$1) => {
  BlockStatement$say("a");
  if (c$1) {
    BlockStatement$say("b");
  }
  return 1;
};
const BlockStatement$discarded = (c$1) => {
  BlockStatement$say("a");
  if (c$1) {
    BlockStatement$say("b");
  }
  return 1;
};
const BlockStatement$main = Node$printLines([]);
export { BlockStatement$main, BlockStatement$statement, BlockStatement$discarded };
//# sourceMappingURL=BlockStatement.mjs.map
