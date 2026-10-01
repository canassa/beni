import { String$compare } from "./_core/String.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const DerivedEmissionOrder$Amber$$order = { Dawn: 0, Dusk: 1 };
const DerivedEmissionOrder$Zinc$$order = { Plate: 0, Ingot: 1 };
const DerivedEmissionOrder$Amber$$compare = ($x, $y) => {
  const $a = DerivedEmissionOrder$Amber$$order[$x];
  const $b = DerivedEmissionOrder$Amber$$order[$y];
  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
};
const DerivedEmissionOrder$Amber$$eq = ($x, $y) => $x === $y;
const DerivedEmissionOrder$Zinc$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return DerivedEmissionOrder$Zinc$$order[$x.$] < DerivedEmissionOrder$Zinc$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Plate":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      const $o$0 = $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
      if ($o$0 !== "EQ") {
        return $o$0;
      }
      return $x.b < $y.b ? "LT" : $x.b > $y.b ? "GT" : "EQ";
  }
};
const DerivedEmissionOrder$Zinc$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Plate":
      return $x.a === $y.a;
    default:
      return $x.a === $y.a && $x.b === $y.b;
  }
};
const DerivedEmissionOrder$compare$prim = ($x, $y) => $x < $y ? "LT" : $x > $y ? "GT" : "EQ";
const DerivedEmissionOrder$compare$r$hue$name = ($m$0, $m$1, $x, $y) => {
  const $o$0 = $m$0($x.hue, $y.hue);
  if ($o$0 !== "EQ") {
    return $o$0;
  }
  return $m$1($x.name, $y.name);
};
const DerivedEmissionOrder$eq$prim = ($x, $y) => $x === $y;
const DerivedEmissionOrder$eq$r$hue$name = ($m$0, $m$1, $x, $y) => $m$0($x.hue, $y.hue) && $m$1($x.name, $y.name);
const DerivedEmissionOrder$sorted = (a$1, b$2) => DerivedEmissionOrder$compare$r$hue$name(DerivedEmissionOrder$compare$prim, String$compare, a$1, b$2) === "LT";
const DerivedEmissionOrder$same = (a$1, b$2) => DerivedEmissionOrder$eq$r$hue$name(DerivedEmissionOrder$eq$prim, DerivedEmissionOrder$eq$prim, a$1, b$2);
const DerivedEmissionOrder$main = Node$printLines([]);
export { DerivedEmissionOrder$Amber$$compare, DerivedEmissionOrder$Amber$$eq, DerivedEmissionOrder$Zinc$$compare, DerivedEmissionOrder$Zinc$$eq, DerivedEmissionOrder$main, DerivedEmissionOrder$sorted, DerivedEmissionOrder$same };
//# sourceMappingURL=DerivedEmissionOrder.mjs.map
