import { String$compare } from "./core/String.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const PrimitiveEvidence$compare$char = ($x, $y) => {
  const $a = $x.codePointAt(0);
  const $b = $y.codePointAt(0);
  return $a < $b ? "LT" : $a > $b ? "GT" : "EQ";
};
const PrimitiveEvidence$compare$prim = ($x, $y) => $x < $y ? "LT" : $x > $y ? "GT" : "EQ";
const PrimitiveEvidence$eq$prim = ($x, $y) => $x === $y;
const PrimitiveEvidence$before = ($m$0, x$1, y$2) => $m$0(x$1, y$2) === "LT";
const PrimitiveEvidence$sameAs = ($m$0, x$1, y$2) => $m$0(x$1, y$2);
const PrimitiveEvidence$ints = (a$1, b$2) => PrimitiveEvidence$before(PrimitiveEvidence$compare$prim, a$1, b$2);
const PrimitiveEvidence$chars = (a$1, b$2) => PrimitiveEvidence$before(PrimitiveEvidence$compare$char, a$1, b$2);
const PrimitiveEvidence$strings = (a$1, b$2) => PrimitiveEvidence$before(String$compare, a$1, b$2);
const PrimitiveEvidence$sameInts = (a$1, b$2) => PrimitiveEvidence$sameAs(PrimitiveEvidence$eq$prim, a$1, b$2);
const PrimitiveEvidence$main = Node$printLines({ $: 0, a: null, b: null });
export { PrimitiveEvidence$main, PrimitiveEvidence$ints, PrimitiveEvidence$chars, PrimitiveEvidence$strings, PrimitiveEvidence$sameInts };
