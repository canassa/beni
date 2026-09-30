import { deep as _derived$deep, listEq as _derived$listEq, listCompare as _derived$listCompare } from "./_core/_derived.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
import { String$compare } from "./_core/String.mjs";
const EqAgainstConstructor$Pair$$compare = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return _derived$deep(EqAgainstConstructor$Pair$$compare$$steps($x, $y), $d);
  }
  const $o$0 = _derived$listCompare(EqAgainstConstructor$compare$prim, $x.a, $y.a, $d + 1);
  if ($o$0 !== "EQ") {
    return $o$0;
  }
  return String$compare($x.b, $y.b);
};
function* EqAgainstConstructor$Pair$$compare$$steps($x, $y) {
  let $e;
  $e = _derived$listCompare(EqAgainstConstructor$compare$prim, $x.a, $y.a, 2**30);
  if (typeof $e === "object") {
    $e = yield $e;
  }
  if ($e !== "EQ") {
    return $e;
  }
  return String$compare($x.b, $y.b);
}
const EqAgainstConstructor$Pair$$eq = ($x, $y, $d = 0) => {
  if ($d > 400) {
    return _derived$deep(EqAgainstConstructor$Pair$$eq$$steps($x, $y), $d);
  }
  return _derived$listEq(EqAgainstConstructor$eq$prim, $x.a, $y.a, $d + 1) && $x.b === $y.b;
};
function* EqAgainstConstructor$Pair$$eq$$steps($x, $y) {
  let $e;
  $e = _derived$listEq(EqAgainstConstructor$eq$prim, $x.a, $y.a, 2**30);
  if (typeof $e === "object") {
    $e = yield $e;
  }
  if (!$e) {
    return false;
  }
  return $x.b === $y.b;
}
const EqAgainstConstructor$compare$prim = ($x, $y) => $x < $y ? "LT" : $x > $y ? "GT" : "EQ";
const EqAgainstConstructor$eq$prim = ($x, $y) => $x === $y;
const EqAgainstConstructor$isSelected = (model$1, id$2) => model$1.selected.$ === "Just" && model$1.selected.a === id$2;
const EqAgainstConstructor$nothing = (m$1) => m$1.$ !== "Nothing";
const EqAgainstConstructor$nested = (m$1, n$2) => {
  const $t$1 = n$2 + 1;
  return m$1.$ === "Just" && (m$1.a.$ === "Just" && m$1.a.a === $t$1);
};
const EqAgainstConstructor$listField = (p$1) => EqAgainstConstructor$Pair$$eq(p$1, { $: "Pair", a: { $: 1, a: 1, b: { $: 0, a: null, b: null } }, b: "a" });
const EqAgainstConstructor$main = Node$printLines({ $: 0, a: null, b: null });
export { EqAgainstConstructor$Pair$$compare, EqAgainstConstructor$Pair$$eq, EqAgainstConstructor$main, EqAgainstConstructor$isSelected, EqAgainstConstructor$nothing, EqAgainstConstructor$nested, EqAgainstConstructor$listField };
