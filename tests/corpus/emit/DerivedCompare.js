import { String$compare } from "./core/String.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const DerivedCompare$compare$char = ($x, $y) => {
  const $a = $x.codePointAt(0);
  const $b = $y.codePointAt(0);
  return $a < $b ? "LT" : $a > $b ? "GT" : "EQ";
};
const DerivedCompare$compare$prim = ($x, $y) => $x < $y ? "LT" : $x > $y ? "GT" : "EQ";
const DerivedCompare$compare$r$x$y = ($m$0, $m$1, $x, $y) => {
  const $o$0 = $m$0($x.x, $y.x);
  if ($o$0 !== "EQ") {
    return $o$0;
  }
  return $m$1($x.y, $y.y);
};
const DerivedCompare$compare$t2 = ($m$0, $m$1, $x, $y) => {
  const $o$0 = $m$0($x.a, $y.a);
  if ($o$0 !== "EQ") {
    return $o$0;
  }
  return $m$1($x.b, $y.b);
};
const DerivedCompare$compare$t3 = ($m$0, $m$1, $m$2, $x, $y) => {
  const $o$0 = $m$0($x.a, $y.a);
  if ($o$0 !== "EQ") {
    return $o$0;
  }
  const $o$1 = $m$1($x.b, $y.b);
  if ($o$1 !== "EQ") {
    return $o$1;
  }
  return $m$2($x.c, $y.c);
};
const DerivedCompare$compare$unit = ($x, $y) => "EQ";
const DerivedCompare$before = (a$1, b$2) => DerivedCompare$compare$r$x$y(DerivedCompare$compare$prim, String$compare, a$1, b$2) === "LT";
const DerivedCompare$atLeast = (a$1, b$2) => DerivedCompare$compare$r$x$y(DerivedCompare$compare$prim, String$compare, a$1, b$2) !== "LT";
const DerivedCompare$pairAtMost = (a$1, b$2) => DerivedCompare$compare$t2(DerivedCompare$compare$prim, DerivedCompare$compare$prim, a$1, b$2) !== "GT";
const DerivedCompare$mixedAfter = (a$1, b$2) => DerivedCompare$compare$t2(DerivedCompare$compare$char, DerivedCompare$compare$prim, a$1, b$2) === "GT";
const DerivedCompare$tripleBefore = (a$1, b$2) => DerivedCompare$compare$t3(DerivedCompare$compare$prim, DerivedCompare$compare$char, String$compare, a$1, b$2) === "LT";
const DerivedCompare$unitAtMost = (a$1, b$2) => DerivedCompare$compare$unit(a$1, b$2) !== "GT";
const DerivedCompare$order = ($m$0, x$1, y$2) => $m$0(x$1, y$2);
const DerivedCompare$rank = (r$1) => DerivedCompare$order(($p$1, $p$2) => DerivedCompare$compare$r$x$y(DerivedCompare$compare$prim, String$compare, $p$1, $p$2), r$1, r$1);
const DerivedCompare$main = Node$printLines({ $: 0, a: null, b: null });
export { DerivedCompare$main, DerivedCompare$before, DerivedCompare$atLeast, DerivedCompare$pairAtMost, DerivedCompare$mixedAfter, DerivedCompare$tripleBefore, DerivedCompare$unitAtMost, DerivedCompare$rank };
