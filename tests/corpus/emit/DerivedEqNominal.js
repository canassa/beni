import { deep as _derived$deep } from "./_core/_derived.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const DerivedEqNominal$Colour$$order = { Red: 0, Green: 1, Blue: 2 };
const DerivedEqNominal$Shape$$order = { Circle: 0, Rect: 1 };
const DerivedEqNominal$Tree$$order = { Leaf: 0, Node: 1 };
const DerivedEqNominal$Box$$compare = ($m$0, $x, $y, $d = 0) => $d > 400 ? _derived$deep([$m$0, $x.a, $y.a], $d) : $m$0($x.a, $y.a, $d + 1);
const DerivedEqNominal$Box$$eq = ($m$0, $x, $y, $d = 0) => $d > 400 ? _derived$deep([$m$0, $x.a, $y.a], $d) : $m$0($x.a, $y.a, $d + 1);
const DerivedEqNominal$Colour$$compare = ($x, $y) => {
  const $a = DerivedEqNominal$Colour$$order[$x];
  const $b = DerivedEqNominal$Colour$$order[$y];
  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
};
const DerivedEqNominal$Colour$$eq = ($x, $y) => $x === $y;
const DerivedEqNominal$Metre$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const DerivedEqNominal$Metre$$eq = ($x, $y) => $x.a === $y.a;
const DerivedEqNominal$Shape$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return DerivedEqNominal$Shape$$order[$x.$] < DerivedEqNominal$Shape$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Circle":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      const $o$0 = $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
      if ($o$0 !== "EQ") {
        return $o$0;
      }
      return $x.b < $y.b ? "LT" : $x.b > $y.b ? "GT" : "EQ";
  }
};
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
const DerivedEqNominal$Tree$$compare = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return _derived$deep(DerivedEqNominal$Tree$$compare$$steps($x, $y), $d);
  }
  for (;;) {
    if ($x.$ !== $y.$) {
      return DerivedEqNominal$Tree$$order[$x.$] < DerivedEqNominal$Tree$$order[$y.$] ? "LT" : "GT";
    }
    switch ($x.$) {
      case "Leaf":
        return "EQ";
      default:
        const $o$0 = DerivedEqNominal$Tree$$compare($x.a, $y.a, $d + 1);
        if ($o$0 !== "EQ") {
          return $o$0;
        }
        const $o$1 = $x.b < $y.b ? "LT" : $x.b > $y.b ? "GT" : "EQ";
        if ($o$1 !== "EQ") {
          return $o$1;
        }
        $x = $x.c;
        $y = $y.c;
        continue;
    }
  }
};
function* DerivedEqNominal$Tree$$compare$$steps($x, $y) {
  let $e;
  for (;;) {
    if ($x.$ !== $y.$) {
      return DerivedEqNominal$Tree$$order[$x.$] < DerivedEqNominal$Tree$$order[$y.$] ? "LT" : "GT";
    }
    switch ($x.$) {
      case "Leaf":
        return "EQ";
      default:
        $e = DerivedEqNominal$Tree$$compare($x.a, $y.a, 2**30);
        if (typeof $e === "object") {
          $e = yield $e;
        }
        if ($e !== "EQ") {
          return $e;
        }
        $e = $x.b < $y.b ? "LT" : $x.b > $y.b ? "GT" : "EQ";
        if ($e !== "EQ") {
          return $e;
        }
        $x = $x.c;
        $y = $y.c;
        continue;
    }
  }
}
const DerivedEqNominal$Tree$$eq = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return _derived$deep(DerivedEqNominal$Tree$$eq$$steps($x, $y), $d);
  }
  for (;;) {
    if ($x.$ !== $y.$) {
      return false;
    }
    switch ($x.$) {
      case "Leaf":
        return true;
      default:
        if (!DerivedEqNominal$Tree$$eq($x.a, $y.a, $d + 1)) {
          return false;
        }
        if ($x.b !== $y.b) {
          return false;
        }
        $x = $x.c;
        $y = $y.c;
        continue;
    }
  }
};
function* DerivedEqNominal$Tree$$eq$$steps($x, $y) {
  let $e;
  for (;;) {
    if ($x.$ !== $y.$) {
      return false;
    }
    switch ($x.$) {
      case "Leaf":
        return true;
      default:
        $e = DerivedEqNominal$Tree$$eq($x.a, $y.a, 2**30);
        if (typeof $e === "object") {
          $e = yield $e;
        }
        if (!$e) {
          return false;
        }
        if ($x.b !== $y.b) {
          return false;
        }
        $x = $x.c;
        $y = $y.c;
        continue;
    }
  }
}
const DerivedEqNominal$eq$prim = ($x, $y) => $x === $y;
const DerivedEqNominal$sameShape = (a$1, b$2) => DerivedEqNominal$Shape$$eq(a$1, b$2);
const DerivedEqNominal$sameTree = (a$1, b$2) => DerivedEqNominal$Tree$$eq(a$1, b$2);
const DerivedEqNominal$sameBoxes = (a$1, b$2) => DerivedEqNominal$Box$$eq(DerivedEqNominal$eq$prim, a$1, b$2);
const DerivedEqNominal$main = Node$printLines([]);
export { DerivedEqNominal$Box$$compare, DerivedEqNominal$Box$$eq, DerivedEqNominal$Colour$$compare, DerivedEqNominal$Colour$$eq, DerivedEqNominal$Metre$$compare, DerivedEqNominal$Metre$$eq, DerivedEqNominal$Shape$$compare, DerivedEqNominal$Shape$$eq, DerivedEqNominal$Tree$$compare, DerivedEqNominal$Tree$$eq, DerivedEqNominal$main, DerivedEqNominal$sameShape, DerivedEqNominal$sameTree, DerivedEqNominal$sameBoxes };
