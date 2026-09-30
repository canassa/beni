import { Node$printLines } from "./_platform/Node.mjs";
import { String$fromInt } from "./_core/String.mjs";
const DceDerived$Empty = { $: "Empty", a: null };
const DceDerived$Kept$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Empty":
      return true;
    default:
      return DceDerived$Payload$$eq($x.a, $y.a);
  }
};
const DceDerived$Payload$$eq = ($x, $y) => $x.a === $y.a;
const DceDerived$same = (a$1, b$2) => DceDerived$Kept$$eq(a$1, b$2) ? "yes" : "no";
const DceDerived$main = Node$printLines([DceDerived$same(DceDerived$Empty, { $: "Holds", a: { $: "Payload", a: 1 } }), String$fromInt(0)]);
export { DceDerived$Kept$$eq, DceDerived$Payload$$eq, DceDerived$main, DceDerived$same };
