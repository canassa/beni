import { Node$printLines } from "./_platform/Node.mjs";
const DceEqAgainstConstructor$isPicked = (picked$1, n$2) => picked$1.$ === "Just" && picked$1.a === n$2 ? "picked" : "not picked";
const DceEqAgainstConstructor$notTwo = (shape$1) => !(shape$1.$ === "Circle" && shape$1.a === 2) ? "other" : "circle 2";
const DceEqAgainstConstructor$main = Node$printLines({ $: 1, a: DceEqAgainstConstructor$isPicked({ $: "Just", a: 3 }, 3), b: { $: 1, a: DceEqAgainstConstructor$notTwo({ $: "Square", a: 2 }), b: { $: 0, a: null, b: null } } });
export { DceEqAgainstConstructor$main };
