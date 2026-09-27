import { String$fromInt } from "./_core/String.mjs";
import { Basics$add } from "./_core/Basics.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const MatchNested$Colour$$order = { Red: 0, Blue: 1 };
const MatchNested$Inner$$order = { Leaf: 0, Pair: 1 };
const MatchNested$Shape$$order = { Circle: 0, Square: 1, Tri: 2 };
const MatchNested$Colour$$compare = ($x, $y) => {
  const $a = MatchNested$Colour$$order[$x];
  const $b = MatchNested$Colour$$order[$y];
  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
};
const MatchNested$Colour$$eq = ($x, $y) => $x === $y;
const MatchNested$Inner$$compare = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return MatchNested$derived$deep(MatchNested$Inner$$compare$$steps($x, $y), $d);
  }
  if ($x.$ !== $y.$) {
    return MatchNested$Inner$$order[$x.$] < MatchNested$Inner$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Leaf":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      const $o$0 = MatchNested$Inner$$compare($x.a, $y.a, $d + 1);
      if ($o$0 !== "EQ") {
        return $o$0;
      }
      return MatchNested$Inner$$compare($x.b, $y.b, $d + 1);
  }
};
function* MatchNested$Inner$$compare$$steps($x, $y) {
  let $e;
  if ($x.$ !== $y.$) {
    return MatchNested$Inner$$order[$x.$] < MatchNested$Inner$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Leaf":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      $e = MatchNested$Inner$$compare($x.a, $y.a, 1073741824);
      if (typeof $e === "object") {
        $e = yield $e;
      }
      if ($e !== "EQ") {
        return $e;
      }
      return MatchNested$Inner$$compare($x.b, $y.b, 1073741824);
  }
}
const MatchNested$Inner$$eq = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return MatchNested$derived$deep(MatchNested$Inner$$eq$$steps($x, $y), $d);
  }
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Leaf":
      return $x.a === $y.a;
    default:
      return MatchNested$Inner$$eq($x.a, $y.a, $d + 1) && MatchNested$Inner$$eq($x.b, $y.b, $d + 1);
  }
};
function* MatchNested$Inner$$eq$$steps($x, $y) {
  let $e;
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Leaf":
      return $x.a === $y.a;
    default:
      $e = MatchNested$Inner$$eq($x.a, $y.a, 1073741824);
      if (typeof $e === "object") {
        $e = yield $e;
      }
      if (!$e) {
        return false;
      }
      return MatchNested$Inner$$eq($x.b, $y.b, 1073741824);
  }
}
const MatchNested$Shape$$compare = ($x, $y) => {
  const $a = MatchNested$Shape$$order[$x];
  const $b = MatchNested$Shape$$order[$y];
  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
};
const MatchNested$Shape$$eq = ($x, $y) => $x === $y;
const MatchNested$derived$deep = ($g, $d) => {
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
const MatchNested$describe = (shape$1, colour$2) => {
  $j$0$3: {
    switch (shape$1) {
      case "Circle":
        {
          if (colour$2 === "Red") {
            return "red circle";
          } else {
            return "circle";
          }
        }
      case "Square":
        {
          if (colour$2 === "Red") {
            return "red square";
          } else {
            break $j$0$3;
          }
        }
      default:
        {
          if (colour$2 === "Blue") {
            break $j$0$3;
          } else {
            return "thing";
          }
        }
    }
  }
  return "blue thing";
};
const MatchNested$nested = (i$1) => {
  if (i$1.$ === "Leaf") {
    const n$5 = i$1.a;
    return `leaf ${String$fromInt(n$5)}`;
  } else {
    if (i$1.a.$ === "Leaf") {
      if (i$1.b.$ === "Leaf") {
        const a$2 = i$1.a.a;
        const b$3 = i$1.b.a;
        return `two leaves ${String$fromInt(Basics$add(a$2, b$3))}`;
      } else {
        const a$4 = i$1.a.a;
        return `left leaf ${String$fromInt(a$4)}`;
      }
    } else {
      return "pair";
    }
  }
};
const MatchNested$main = Node$printLines({ $: 0, a: null, b: null });
export { MatchNested$Colour$$compare, MatchNested$Colour$$eq, MatchNested$Inner$$compare, MatchNested$Inner$$eq, MatchNested$Shape$$compare, MatchNested$Shape$$eq, MatchNested$main, MatchNested$describe, MatchNested$nested };
