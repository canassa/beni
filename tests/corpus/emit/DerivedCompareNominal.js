import { deep as _derived$deep } from "./_core/_derived.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
import { String$compare } from "./_core/String.mjs";
const DerivedCompareNominal$Colour$$order = { Red: 0, Green: 1, Blue: 2 };
const DerivedCompareNominal$Label$$order = { Initial: 0, Named: 1 };
const DerivedCompareNominal$Outcome$$order = { Ok: 0, Err: 1 };
const DerivedCompareNominal$Shape$$order = { Circle: 0, Rect: 1 };
const DerivedCompareNominal$Tree$$order = { Leaf: 0, Node: 1 };
const DerivedCompareNominal$Colour$$compare = ($x, $y) => {
  const $a = DerivedCompareNominal$Colour$$order[$x];
  const $b = DerivedCompareNominal$Colour$$order[$y];
  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
};
const DerivedCompareNominal$Colour$$eq = ($x, $y) => $x === $y;
const DerivedCompareNominal$Label$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return DerivedCompareNominal$Label$$order[$x.$] < DerivedCompareNominal$Label$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Initial":
      const $t$1 = $x.a.codePointAt(0);
      const $t$2 = $y.a.codePointAt(0);
      return $t$1 < $t$2 ? "LT" : $t$1 > $t$2 ? "GT" : "EQ";
    default:
      return String$compare($x.a, $y.a);
  }
};
const DerivedCompareNominal$Label$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Initial":
      return $x.a === $y.a;
    default:
      return $x.a === $y.a;
  }
};
const DerivedCompareNominal$Outcome$$compare = ($m$0, $m$1, $x, $y, $d = 0) => {
  if ($x.$ !== $y.$) {
    return DerivedCompareNominal$Outcome$$order[$x.$] < DerivedCompareNominal$Outcome$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Ok":
      return $d > 400 ? _derived$deep([$m$1, $x.a, $y.a], $d) : $m$1($x.a, $y.a, $d + 1);
    default:
      return $d > 400 ? _derived$deep([$m$0, $x.a, $y.a], $d) : $m$0($x.a, $y.a, $d + 1);
  }
};
const DerivedCompareNominal$Outcome$$eq = ($m$0, $m$1, $x, $y, $d = 0) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Ok":
      return $d > 400 ? _derived$deep([$m$1, $x.a, $y.a], $d) : $m$1($x.a, $y.a, $d + 1);
    default:
      return $d > 400 ? _derived$deep([$m$0, $x.a, $y.a], $d) : $m$0($x.a, $y.a, $d + 1);
  }
};
const DerivedCompareNominal$Shape$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return DerivedCompareNominal$Shape$$order[$x.$] < DerivedCompareNominal$Shape$$order[$y.$] ? "LT" : "GT";
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
const DerivedCompareNominal$Shape$$eq = ($x, $y) => {
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
const DerivedCompareNominal$Tree$$compare = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return _derived$deep(DerivedCompareNominal$Tree$$compare$$steps($x, $y), $d);
  }
  for (;;) {
    if ($x.$ !== $y.$) {
      return DerivedCompareNominal$Tree$$order[$x.$] < DerivedCompareNominal$Tree$$order[$y.$] ? "LT" : "GT";
    }
    switch ($x.$) {
      case "Leaf":
        return "EQ";
      default:
        const $o$0 = DerivedCompareNominal$Tree$$compare($x.a, $y.a, $d + 1);
        if ($o$0 !== "EQ") {
          return $o$0;
        }
        $x = $x.b;
        $y = $y.b;
        continue;
    }
  }
};
function* DerivedCompareNominal$Tree$$compare$$steps($x, $y) {
  let $e;
  for (;;) {
    if ($x.$ !== $y.$) {
      return DerivedCompareNominal$Tree$$order[$x.$] < DerivedCompareNominal$Tree$$order[$y.$] ? "LT" : "GT";
    }
    switch ($x.$) {
      case "Leaf":
        return "EQ";
      default:
        $e = DerivedCompareNominal$Tree$$compare($x.a, $y.a, 2**30);
        if (typeof $e === "object") {
          $e = yield $e;
        }
        if ($e !== "EQ") {
          return $e;
        }
        $x = $x.b;
        $y = $y.b;
        continue;
    }
  }
}
const DerivedCompareNominal$Tree$$eq = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return _derived$deep(DerivedCompareNominal$Tree$$eq$$steps($x, $y), $d);
  }
  for (;;) {
    if ($x.$ !== $y.$) {
      return false;
    }
    switch ($x.$) {
      case "Leaf":
        return true;
      default:
        if (!DerivedCompareNominal$Tree$$eq($x.a, $y.a, $d + 1)) {
          return false;
        }
        $x = $x.b;
        $y = $y.b;
        continue;
    }
  }
};
function* DerivedCompareNominal$Tree$$eq$$steps($x, $y) {
  let $e;
  for (;;) {
    if ($x.$ !== $y.$) {
      return false;
    }
    switch ($x.$) {
      case "Leaf":
        return true;
      default:
        $e = DerivedCompareNominal$Tree$$eq($x.a, $y.a, 2**30);
        if (typeof $e === "object") {
          $e = yield $e;
        }
        if (!$e) {
          return false;
        }
        $x = $x.b;
        $y = $y.b;
        continue;
    }
  }
}
const DerivedCompareNominal$Wrapper$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const DerivedCompareNominal$Wrapper$$eq = ($x, $y) => $x.a === $y.a;
const DerivedCompareNominal$main = Node$printLines({ $: 0, a: null, b: null });
export { DerivedCompareNominal$Colour$$compare, DerivedCompareNominal$Colour$$eq, DerivedCompareNominal$Label$$compare, DerivedCompareNominal$Label$$eq, DerivedCompareNominal$Outcome$$compare, DerivedCompareNominal$Outcome$$eq, DerivedCompareNominal$Shape$$compare, DerivedCompareNominal$Shape$$eq, DerivedCompareNominal$Tree$$compare, DerivedCompareNominal$Tree$$eq, DerivedCompareNominal$Wrapper$$compare, DerivedCompareNominal$Wrapper$$eq, DerivedCompareNominal$main };
