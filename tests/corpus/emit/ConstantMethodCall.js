import { Basics$add } from "./core/Basics.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const ConstantMethodCall$bump = (c$1, step$2) => {
  let $t$1;
  const n$3 = c$1.a;
  $t$1 = { $: "Counter", a: Basics$add(n$3, step$2) };
  return $t$1;
};
const ConstantMethodCall$bumped = ConstantMethodCall$bump({ $: "Counter", a: 1 }, 2);
const ConstantMethodCall$main = Node$printLines({ $: 0, a: null, b: null });
export { ConstantMethodCall$main, ConstantMethodCall$bumped, ConstantMethodCall$bump };
