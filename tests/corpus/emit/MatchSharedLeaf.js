import { String$fromInt, String$append } from "./_core/String.mjs";
import { Basics$add } from "./_core/Basics.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const MatchSharedLeaf$Flag$$order = { On: 0, Off: 1 };
const MatchSharedLeaf$Flag$$compare = ($x, $y) => {
  const $a = MatchSharedLeaf$Flag$$order[$x];
  const $b = MatchSharedLeaf$Flag$$order[$y];
  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
};
const MatchSharedLeaf$Flag$$eq = ($x, $y) => $x === $y;
const MatchSharedLeaf$verdict = (x$1, y$2, flag$3) => {
  $j$0$2: {
    if (flag$3 === "On") {
      if (x$1 === 0) {
        const b$4 = y$2;
        return `on axis ${String$fromInt(b$4)}`;
      } else {
        break $j$0$2;
      }
    } else {
      if (y$2 === 0) {
        const a$5 = x$1;
        return `off axis ${String$fromInt(a$5)}`;
      } else {
        break $j$0$2;
      }
    }
  }
  const a$6 = x$1;
  const b$7 = y$2;
  return `sum ${String$fromInt(Basics$add(a$6, b$7))}`;
};
const MatchSharedLeaf$report = (x$1, y$2, flag$3) => {
  let $t$1;
  $c$0: {
    $j$0$2: {
      if (flag$3 === "On") {
        if (x$1 === 0) {
          const b$4 = y$2;
          $t$1 = `on axis ${String$fromInt(b$4)}`;
          break $c$0;
        } else {
          break $j$0$2;
        }
      } else {
        if (y$2 === 0) {
          const a$5 = x$1;
          $t$1 = `off axis ${String$fromInt(a$5)}`;
          break $c$0;
        } else {
          break $j$0$2;
        }
      }
    }
    const a$6 = x$1;
    const b$7 = y$2;
    $t$1 = `sum ${String$fromInt(Basics$add(a$6, b$7))}`;
  }
  return String$append("> ", $t$1);
};
const MatchSharedLeaf$main = Node$printLines({ $: 0, a: null, b: null });
export { MatchSharedLeaf$Flag$$compare, MatchSharedLeaf$Flag$$eq, MatchSharedLeaf$main, MatchSharedLeaf$verdict, MatchSharedLeaf$report };
