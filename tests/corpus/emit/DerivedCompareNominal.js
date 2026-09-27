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
  if ($d > 400) {
    return DerivedCompareNominal$derived$deep(DerivedCompareNominal$Outcome$$compare$$steps($m$0, $m$1, $x, $y), $d);
  }
  if ($x.$ !== $y.$) {
    return DerivedCompareNominal$Outcome$$order[$x.$] < DerivedCompareNominal$Outcome$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Ok":
      return $m$1($x.a, $y.a, $d + 1);
    default:
      return $m$0($x.a, $y.a, $d + 1);
  }
};
function* DerivedCompareNominal$Outcome$$compare$$steps($m$0, $m$1, $x, $y) {
  if ($x.$ !== $y.$) {
    return DerivedCompareNominal$Outcome$$order[$x.$] < DerivedCompareNominal$Outcome$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Ok":
      return $m$1($x.a, $y.a, 1073741824);
    default:
      return $m$0($x.a, $y.a, 1073741824);
  }
}
const DerivedCompareNominal$Outcome$$eq = ($m$0, $m$1, $x, $y, $d = 0) => {
  if ($d > 400) {
    return DerivedCompareNominal$derived$deep(DerivedCompareNominal$Outcome$$eq$$steps($m$0, $m$1, $x, $y), $d);
  }
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Ok":
      return $m$1($x.a, $y.a, $d + 1);
    default:
      return $m$0($x.a, $y.a, $d + 1);
  }
};
function* DerivedCompareNominal$Outcome$$eq$$steps($m$0, $m$1, $x, $y) {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Ok":
      return $m$1($x.a, $y.a, 1073741824);
    default:
      return $m$0($x.a, $y.a, 1073741824);
  }
}
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
    return DerivedCompareNominal$derived$deep(DerivedCompareNominal$Tree$$compare$$steps($x, $y), $d);
  }
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
      return DerivedCompareNominal$Tree$$compare($x.b, $y.b, $d + 1);
  }
};
function* DerivedCompareNominal$Tree$$compare$$steps($x, $y) {
  let $e;
  if ($x.$ !== $y.$) {
    return DerivedCompareNominal$Tree$$order[$x.$] < DerivedCompareNominal$Tree$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Leaf":
      return "EQ";
    default:
      $e = DerivedCompareNominal$Tree$$compare($x.a, $y.a, 1073741824);
      if (typeof $e === "object") {
        $e = yield $e;
      }
      if ($e !== "EQ") {
        return $e;
      }
      return DerivedCompareNominal$Tree$$compare($x.b, $y.b, 1073741824);
  }
}
const DerivedCompareNominal$Tree$$eq = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return DerivedCompareNominal$derived$deep(DerivedCompareNominal$Tree$$eq$$steps($x, $y), $d);
  }
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Leaf":
      return true;
    default:
      return DerivedCompareNominal$Tree$$eq($x.a, $y.a, $d + 1) && DerivedCompareNominal$Tree$$eq($x.b, $y.b, $d + 1);
  }
};
function* DerivedCompareNominal$Tree$$eq$$steps($x, $y) {
  let $e;
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Leaf":
      return true;
    default:
      $e = DerivedCompareNominal$Tree$$eq($x.a, $y.a, 1073741824);
      if (typeof $e === "object") {
        $e = yield $e;
      }
      if (!$e) {
        return false;
      }
      return DerivedCompareNominal$Tree$$eq($x.b, $y.b, 1073741824);
  }
}
const DerivedCompareNominal$Wrapper$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const DerivedCompareNominal$Wrapper$$eq = ($x, $y) => $x.a === $y.a;
const DerivedCompareNominal$derived$deep = ($g, $d) => {
  if ($d === 1073741824) {
    return $g;
  }
  const $s = [];
  let $t = $g;
  let $v;
  while (true) {
    const $n = $t.next($v);
    $v = $n.value;
    if (typeof $v === "object") {
      if (!$n.done) {
        $s.push($t);
      }
      $t = $v;
      continue;
    }
    if ($s.length === 0) {
      return $v;
    }
    $t = $s.pop();
  }
};
const DerivedCompareNominal$main = Node$printLines({ $: 0, a: null, b: null });
export { DerivedCompareNominal$Colour$$compare, DerivedCompareNominal$Colour$$eq, DerivedCompareNominal$Label$$compare, DerivedCompareNominal$Label$$eq, DerivedCompareNominal$Outcome$$compare, DerivedCompareNominal$Outcome$$eq, DerivedCompareNominal$Shape$$compare, DerivedCompareNominal$Shape$$eq, DerivedCompareNominal$Tree$$compare, DerivedCompareNominal$Tree$$eq, DerivedCompareNominal$Wrapper$$compare, DerivedCompareNominal$Wrapper$$eq, DerivedCompareNominal$main };
