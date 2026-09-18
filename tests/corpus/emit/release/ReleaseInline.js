import { Basics$add, Basics$mul } from "./core/Basics.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const ReleaseInline$Pair$$compare = ($x, $y) => {
  const $o$0 = $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
  if ($o$0 !== "EQ") {
    return $o$0;
  }
  return $x.b < $y.b ? "LT" : $x.b > $y.b ? "GT" : "EQ";
};
const ReleaseInline$Pair$$eq = ($x, $y) => $x.a === $y.a && $x.b === $y.b;
const ReleaseInline$sum = (p$1) => Basics$add(p$1.a, p$1.b);
const ReleaseInline$swap = (p$1) => ({ $: "Pair", a: p$1.b, b: p$1.a });
const ReleaseInline$square = (p$1) => {
  const a$2 = p$1.a;
  return Basics$mul(a$2, a$2);
};
const ReleaseInline$held = (p$1) => {
  const once$2 = ReleaseInline$sum(p$1);
  return Basics$add(once$2, 1);
};
const ReleaseInline$main = Node$printLines({ $: 0, a: null, b: null });
export { ReleaseInline$Pair$$compare, ReleaseInline$Pair$$eq, ReleaseInline$main, ReleaseInline$sum, ReleaseInline$swap, ReleaseInline$square, ReleaseInline$held };
