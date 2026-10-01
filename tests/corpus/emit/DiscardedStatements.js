import { Debug$log } from "./_core/Debug.mjs";
import { String$fromInt } from "./_core/String.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const DiscardedStatements$say = (s$1) => {
  Debug$log("say", s$1);
};
const DiscardedStatements$twice = (c$1) => {
  DiscardedStatements$say("a");
  if (c$1) {
    DiscardedStatements$say("b");
  }
  if (!c$1) {
    DiscardedStatements$say("d");
  }
  DiscardedStatements$say("c");
};
const DiscardedStatements$kept = (c$1) => {
  DiscardedStatements$twice(c$1);
  return null;
};
const DiscardedStatements$pureDiscard = (n$1) => {
  String$fromInt(n$1);
  n$1 * 2;
  return n$1;
};
const DiscardedStatements$main = Node$printLines([]);
export { DiscardedStatements$main, DiscardedStatements$kept, DiscardedStatements$pureDiscard };
//# sourceMappingURL=DiscardedStatements.mjs.map
