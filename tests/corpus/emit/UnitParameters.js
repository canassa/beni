import { Node$printLines } from "./_platform/Node.mjs";
const UnitParameters$thunk = () => 42;
const UnitParameters$later = (n$1) => n$1 + 1;
const UnitParameters$first = ($p$1, n$1) => n$1;
const UnitParameters$lambda = () => () => 7;
const UnitParameters$calls = (n$1) => {
  const f$2 = UnitParameters$lambda();
  return UnitParameters$thunk() + UnitParameters$later(n$1) + UnitParameters$first(null, n$1) + f$2(null);
};
const UnitParameters$main = Node$printLines({ $: 0, a: null, b: null });
export { UnitParameters$main, UnitParameters$thunk, UnitParameters$later, UnitParameters$first, UnitParameters$lambda, UnitParameters$calls };
