import { Node$printLines } from "./platform/Node.mjs";
const DerivedEqNominal$Box$$eq = ($m$0, $x, $y) => $m$0($x.a, $y.a);
const DerivedEqNominal$Colour$$eq = ($x, $y) => $x === $y;
const DerivedEqNominal$Metre$$eq = ($x, $y) => $x.a === $y.a;
const DerivedEqNominal$Shape$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Circle":
      return $x.a === $y.a;
    default:
      return $x.a === $y.a && $x.b === $y.b;
  }
};
const DerivedEqNominal$Tree$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Leaf":
      return true;
    default:
      return DerivedEqNominal$Tree$$eq($x.a, $y.a) && $x.b === $y.b && DerivedEqNominal$Tree$$eq($x.c, $y.c);
  }
};
const DerivedEqNominal$eq$prim = ($x, $y) => $x === $y;
const DerivedEqNominal$sameShape = (a$1, b$2) => DerivedEqNominal$Shape$$eq(a$1, b$2);
const DerivedEqNominal$sameTree = (a$1, b$2) => DerivedEqNominal$Tree$$eq(a$1, b$2);
const DerivedEqNominal$sameBoxes = (a$1, b$2) => DerivedEqNominal$Box$$eq(DerivedEqNominal$eq$prim, a$1, b$2);
const DerivedEqNominal$main = Node$printLines({ $: 0, a: null, b: null });
export { DerivedEqNominal$Box$$eq, DerivedEqNominal$Colour$$eq, DerivedEqNominal$Metre$$eq, DerivedEqNominal$Shape$$eq, DerivedEqNominal$Tree$$eq, DerivedEqNominal$main, DerivedEqNominal$sameShape, DerivedEqNominal$sameTree, DerivedEqNominal$sameBoxes };
