import { Node$printLines } from "./_platform/Node.mjs";
const ConstantMethodCall$Counter$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const ConstantMethodCall$Counter$$eq = ($x, $y) => $x.a === $y.a;
const ConstantMethodCall$bump = (c$1, step$2) => {
  const n$3 = c$1.a;
  return { $: "Counter", a: n$3 + step$2 };
};
const ConstantMethodCall$bumped = ConstantMethodCall$bump({ $: "Counter", a: 1 }, 2);
const ConstantMethodCall$main = Node$printLines({ $: 0, a: null, b: null });
export { ConstantMethodCall$Counter$$compare, ConstantMethodCall$Counter$$eq, ConstantMethodCall$main, ConstantMethodCall$bumped, ConstantMethodCall$bump };
