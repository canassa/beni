import { Node$printLines } from "./_platform/Node.mjs";
import { String$fromInt } from "./_core/String.mjs";
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
const DceDerived$main = Node$printLines({ $: 1, a: DceDerived$same({ $: "Empty", a: null }, { $: "Holds", a: { $: "Payload", a: 1 } }), b: { $: 1, a: String$fromInt(0), b: { $: 0, a: null, b: null } } });
export { DceDerived$Kept$$eq, DceDerived$Payload$$eq, DceDerived$main, DceDerived$same };
